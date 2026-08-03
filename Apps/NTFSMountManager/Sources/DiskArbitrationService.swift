import Foundation
import DiskArbitration
import SwiftUI

/// Watches DiskArbitration for attached NTFS volumes (mounted OR unmounted) and
/// surfaces them to the menu-bar UI. `volumes` is updated on the main queue so
/// SwiftUI bindings update without thread hops.
@MainActor
final class DiskArbitrationService: ObservableObject {
    struct Volume: Identifiable, Equatable {
        let id: String           // bsd name, e.g. "disk6s1"
        let displayName: String  // volume label or device name
        let isMounted: Bool
        let mountPoint: String?
        let mediaSize: UInt64?
    }

    @Published private(set) var volumes: [Volume] = []

    /// Shared session log — set by the app after init. Mount/eject outcomes are
    /// recorded here so the Activity view shows a live in-progress → done trail.
    weak var activityLog: ActivityLog?

    private var session: DASession?
    private var callbackBox: CallbackBox?

    init() {
        startSession()
        refresh()
    }

    deinit {
        // DASession owns its dispatch-queue lifecycle once unscheduled. The
        // session itself is cleaned up by Core Foundation refcounting; we
        // can't touch self.session from a nonisolated deinit under Swift 6
        // strict concurrency, so the schedule-clear happens via a
        // best-effort detached task triggered explicitly by callers via
        // shutdown(). For app-lifetime singletons this is fine.
    }

    func shutdown() {
        if let session = session {
            DASessionSetDispatchQueue(session, nil)
        }
        session = nil
    }

    func refresh() {
        Task {
            let snapshot = await snapshotAllNTFSDisks()
            self.volumes = snapshot
        }
    }

    private func startSession() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return
        }
        self.session = session
        DASessionSetDispatchQueue(session, .main)

        // Subscribe to attach/detach so refresh() runs whenever the set of
        // mounted disks changes. The callbacks must be C-style; box self
        // weakly via an Unmanaged retain.
        let box = CallbackBox(service: self)
        self.callbackBox = box
        let context = Unmanaged.passUnretained(box).toOpaque()

        let attachCallback: DADiskAppearedCallback = { disk, ctx in
            guard let ctx = ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            box.service?.refresh()
            _ = disk
        }
        let disappearCallback: DADiskDisappearedCallback = { disk, ctx in
            guard let ctx = ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            box.service?.refresh()
            _ = disk
        }

        DARegisterDiskAppearedCallback(session, nil, attachCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearCallback, context)
    }

    // Walk all disks via /dev/disk* and filter to ones DiskArbitration says
    // look like NTFS volumes. We don't try to mount/probe them ourselves —
    // DA's filesystem name + content-hint is good enough for the menu list.
    private func snapshotAllNTFSDisks() async -> [Volume] {
        guard let session = session else { return [] }

        // Get all whole disks and their slices via the diskutil URL trick:
        // there's no public DA "list all" API, so iterate /dev/disk*
        // candidates and ask DA for each.
        let candidates: [String] = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
            .filter { $0.hasPrefix("disk") && $0.contains("s") }    // disk6s1 etc — slices, not whole disks
            ?? []

        var result: [Volume] = []
        for bsdName in candidates {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { continue }
            guard let description = DADiskCopyDescription(disk) as? [String: Any] else { continue }

            // Filter to NTFS by filesystem name OR content hint (DA recognizes
            // even unmounted NTFS via the partition's UUID/content type).
            let fsType = description[kDADiskDescriptionVolumeKindKey as String] as? String
            let mediaContent = description[kDADiskDescriptionMediaContentKey as String] as? String
            let isNTFS = fsType?.lowercased() == "ntfs"
                || mediaContent?.contains("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7") == true   // Microsoft Basic Data partition UUID
                || mediaContent?.contains("Microsoft Basic Data") == true
            guard isNTFS else { continue }

            let mountPath: String?
            if let urlValue = description[kDADiskDescriptionVolumePathKey as String] as? URL {
                mountPath = urlValue.path
            } else {
                mountPath = nil
            }
            // Prefer the volume's real name. DiskArbitration's volume-name key
            // is often empty for an fskit-mounted NTFS volume, so fall back to
            // the mount-point folder Finder shows (e.g. /Volumes/SANDISK →
            // "SANDISK", /Volumes/Untitled → "Untitled") before the BSD id.
            let volumeName = (description[kDADiskDescriptionVolumeNameKey as String] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let mountName = mountPath
                .map { ($0 as NSString).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
            let displayName = volumeName ?? mountName ?? bsdName
            let mediaSize = (description[kDADiskDescriptionMediaSizeKey as String] as? UInt64)
                ?? (description[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value

            result.append(Volume(
                id: bsdName,
                displayName: displayName,
                isMounted: mountPath != nil,
                mountPoint: mountPath,
                mediaSize: mediaSize
            ))
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Live mount state for a BSD name, read straight from DiskArbitration
    /// rather than from the last `refresh()` snapshot the views hold.
    private func isMountedNow(_ bsdName: String) -> Bool {
        guard let session = session,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        return description[kDADiskDescriptionVolumePathKey as String] as? URL != nil
    }

    /// Render a DiskArbitration dissenter as text a human can act on.
    ///
    /// `DADissenterGetStatusString` is nil for most `DAReturn` codes — the
    /// framework only populates it when the dissenting client supplied a
    /// message, which the system mounter does not. Falling back to a bare
    /// "mount failed" therefore discards the only diagnostic there is. Read the
    /// status code and name it; keep the raw value so an unmapped code is still
    /// identifiable.
    private static func describe(_ dissenter: DADissenter, verb: String) -> String {
        if let supplied = DADissenterGetStatusString(dissenter) as String?, !supplied.isEmpty {
            return supplied
        }
        // `DAReturn` bridges to Int32 while the `kDAReturn*` constants bridge to
        // Int, so widen once and compare against the framework constants rather
        // than hand-rolled numbers.
        let status = Int(DADissenterGetStatus(dissenter))
        switch status {
        case kDAReturnBusy:
            return "volume is busy — macOS may have re-mounted it automatically"
        case kDAReturnNotMounted:
            return "volume is not mounted"
        case kDAReturnNotPermitted, kDAReturnNotPrivileged:
            return "not permitted — this operation needs elevated privileges"
        case kDAReturnUnsupported:
            return "unsupported by the system mounter"
        case kDAReturnBadArgument:
            return "bad argument"
        case kDAReturnExclusiveAccess:
            return "another process holds exclusive access"
        case kDAReturnNoResources:
            return "out of resources"
        case kDAReturnNotFound:
            return "disk not found"
        case kDAReturnNotReady:
            return "disk not ready"
        case kDAReturnNotWritable:
            return "volume is not writable"
        default:
            return "\(verb) failed (DAReturn 0x\(String(status, radix: 16)))"
        }
    }

    /// Trigger DiskArbitration to mount the volume at its default mount point.
    /// Returns an error string on failure; nil on success.
    func mount(_ volume: Volume) async -> String? {
        let logID = activityLog?.log("Mounting \(volume.displayName)…", status: .running, volume: volume.displayName)

        // The view's snapshot of mount state can be stale by the time the click
        // lands: macOS re-mounts an ejected NTFS volume on its own, so an eject
        // that just succeeded can be undone before the user presses Mount.
        // Re-read the live state instead of dissenting with an opaque busy code.
        if isMountedNow(volume.id) {
            let msg = "already mounted — macOS re-mounted it automatically"
            if let logID { activityLog?.update(logID, status: .success, detail: msg) }
            return nil
        }

        guard let session = session,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.id)
        else {
            let err = "could not resolve \(volume.id)"
            if let logID { activityLog?.update(logID, status: .error, detail: err) }
            return err
        }

        let err: String? = await withCheckedContinuation { continuation in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { _, dissenter, ctx in
                let resultPtr = Unmanaged<ResultBox>.fromOpaque(ctx!).takeRetainedValue()
                if let dissenter = dissenter {
                    resultPtr.result = DiskArbitrationService.describe(dissenter, verb: "mount")
                } else {
                    resultPtr.result = nil
                }
                resultPtr.semaphore.signal()
            }, Unmanaged.passRetained(ResultBox(continuation: continuation)).toOpaque())
        }

        if let logID {
            activityLog?.update(
                logID,
                status: err == nil ? .success : .error,
                detail: err == nil ? "Mounted \(volume.displayName)." : err
            )
        }
        return err
    }

    func unmount(_ volume: Volume) async -> String? {
        let logID = activityLog?.log("Ejecting \(volume.displayName)…", status: .running, volume: volume.displayName)

        guard let session = session,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, volume.id)
        else {
            let err = "could not resolve \(volume.id)"
            if let logID { activityLog?.update(logID, status: .error, detail: err) }
            return err
        }

        let err: String? = await withCheckedContinuation { continuation in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, ctx in
                let resultPtr = Unmanaged<ResultBox>.fromOpaque(ctx!).takeRetainedValue()
                if let dissenter = dissenter {
                    resultPtr.result = DiskArbitrationService.describe(dissenter, verb: "unmount")
                } else {
                    resultPtr.result = nil
                }
                resultPtr.semaphore.signal()
            }, Unmanaged.passRetained(ResultBox(continuation: continuation)).toOpaque())
        }

        if let logID {
            activityLog?.update(
                logID,
                status: err == nil ? .success : .error,
                detail: err == nil ? "Ejected \(volume.displayName)." : "Eject failed: \(err ?? "")"
            )
        }
        return err
    }

    /// Boxed reference to escape Swift across the DA C callback boundary.
    private final class CallbackBox {
        weak var service: DiskArbitrationService?
        init(service: DiskArbitrationService) {
            self.service = service
        }
    }

    /// Boxed continuation for the async DA mount/unmount callbacks.
    private final class ResultBox {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String? = nil
        let continuation: CheckedContinuation<String?, Never>
        init(continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }
        deinit {
            continuation.resume(returning: result)
        }
    }
}
