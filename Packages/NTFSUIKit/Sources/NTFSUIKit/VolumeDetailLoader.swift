import Foundation
import NTFSCore

/// Loading state machine for a volume's detail view. Generic over the load
/// payload so the same idle/loading/loaded/failed transitions back both the
/// info load and the verify action.
public enum LoadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case let .loaded(v) = self { return v }
        return nil
    }
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
    public var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

/// Reads volume facts and runs verify against `NTFSCore.Volume` directly (never
/// shelling out to `ntfsctl`). `@MainActor` so its `@Published` state drives
/// SwiftUI without thread hops; the actual NTFSCore actor work runs off-main and
/// results are mapped on the main actor.
@MainActor
public final class VolumeDetailLoader: ObservableObject {

    // These are `var`, not `let`, because the loader outlives the values it was
    // built from. A SwiftUI view owning this via `@StateObject` evaluates
    // `StateObject(wrappedValue:)` exactly once per view identity — every later
    // `init` with a fresher volume is discarded. Left immutable, a loader
    // created before DiskArbitration reported a mount point keeps `nil`
    // forever, the `statfs` fallback can never fire, and the panel shows the
    // root-only raw-device error instead of capacity. See `configure`.

    /// The BSD device path this loader reads, e.g. `/dev/disk6s1`.
    public private(set) var devicePath: String
    /// Label to surface (DiskArbitration-derived).
    public private(set) var label: String
    /// Whether the underlying mount is writable (read-only today).
    public private(set) var isWritable: Bool
    /// The volume's mount point (e.g. `/Volumes/SANDISK`) when mounted, else nil.
    /// Used for a non-privileged `statfs` fallback when the raw device can't be
    /// opened (Finder-mounted volumes are `root:operator 0640`).
    public private(set) var mountPoint: String?

    @Published public private(set) var info: LoadState<VolumeInfoViewModel> = .idle
    @Published public private(set) var verify: LoadState<VerifyResult> = .idle
    @Published public private(set) var format: LoadState<FormatResult> = .idle
    @Published public private(set) var repair: LoadState<RepairResult> = .idle

    /// Injection seam so unit tests can drive the state machine without a real
    /// device. Production leaves these `nil` and the real NTFSCore path runs.
    private let factsProvider: (@Sendable () async throws -> VolumeFacts)?
    private let verifyProvider: (@Sendable () async throws -> VerifyResult)?
    /// Receives the requested label; returns the format outcome. Tests inject a
    /// closure that never touches a real device.
    private let formatProvider: (@Sendable (String) async throws -> FormatResult)?
    private let repairProvider: (@Sendable () async throws -> RepairResult)?

    public init(
        devicePath: String,
        label: String,
        isWritable: Bool,
        mountPoint: String? = nil,
        factsProvider: (@Sendable () async throws -> VolumeFacts)? = nil,
        verifyProvider: (@Sendable () async throws -> VerifyResult)? = nil,
        formatProvider: (@Sendable (String) async throws -> FormatResult)? = nil,
        repairProvider: (@Sendable () async throws -> RepairResult)? = nil
    ) {
        self.devicePath = devicePath
        self.label = label
        self.isWritable = isWritable
        self.mountPoint = mountPoint
        self.factsProvider = factsProvider
        self.verifyProvider = verifyProvider
        self.formatProvider = formatProvider
        self.repairProvider = repairProvider
    }

    /// Re-point this loader at the current state of the same volume.
    ///
    /// Call before `load()` whenever the owning view's volume value may have
    /// changed — most importantly when `mountPoint` appears or disappears,
    /// since that decides whether the non-privileged `statfs` path is available
    /// at all. Returns `true` when something actually changed, so callers can
    /// skip a redundant reload.
    @discardableResult
    public func configure(
        devicePath: String,
        label: String,
        isWritable: Bool,
        mountPoint: String?
    ) -> Bool {
        let changed = devicePath != self.devicePath
            || label != self.label
            || isWritable != self.isWritable
            || mountPoint != self.mountPoint
        guard changed else { return false }
        self.devicePath = devicePath
        self.label = label
        self.isWritable = isWritable
        self.mountPoint = mountPoint
        return true
    }

    /// Load volume facts via NTFSCore and map to the display view-model.
    public func load() async {
        info = .loading
        do {
            let facts: VolumeFacts
            if let provider = factsProvider {
                facts = try await provider()
            } else {
                facts = try await Self.readFacts(devicePath: devicePath, mountPoint: mountPoint, label: label, isWritable: isWritable)
            }
            info = .loaded(VolumeInfoViewModel(facts: facts))
        } catch {
            info = .failed(Self.message(for: error))
        }
    }

    /// Run the verify-equivalent and surface clean/dirty + problems.
    public func runVerify() async {
        verify = .loading
        do {
            let result: VerifyResult
            if let provider = verifyProvider {
                result = try await provider()
            } else {
                result = try await Self.readVerify(devicePath: devicePath)
            }
            verify = .loaded(result)
        } catch {
            verify = .failed(Self.message(for: error))
        }
    }

    /// Format the device as NTFS via `NTFSCore.Volume.formatNTFS`. DESTRUCTIVE —
    /// callers must gate this behind a confirmation dialog naming the device.
    /// The device must be unmounted; the loader opens it writable, formats,
    /// flushes, and releases the advisory lock.
    public func runFormat(label requestedLabel: String) async {
        format = .loading
        do {
            let result: FormatResult
            if let provider = formatProvider {
                result = try await provider(requestedLabel)
            } else {
                result = try await Self.performFormat(devicePath: devicePath, label: requestedLabel)
            }
            format = .loaded(result)
            // The on-disk state changed: re-read facts so the dashboard reflects
            // the fresh, empty volume.
            await load()
        } catch {
            format = .failed(Self.message(for: error))
        }
    }

    /// Run the HONEST repair path: a consistency audit plus a dirty-bit check.
    /// If the volume is merely dirty but the audit is clean, clear the dirty
    /// flag. If the audit finds real corruption, report it and advise Windows
    /// `chkdsk /F` — NTFSCore has no in-place repair and we never claim to fix
    /// corruption.
    public func runRepair() async {
        repair = .loading
        do {
            let result: RepairResult
            if let provider = repairProvider {
                result = try await provider()
            } else {
                result = try await Self.performRepair(devicePath: devicePath)
            }
            repair = .loaded(result)
            // Dirty bit may have been cleared: refresh facts + verify view.
            await load()
        } catch {
            repair = .failed(Self.message(for: error))
        }
    }

    // MARK: - Real NTFSCore reads (run off the main actor)

    /// Read volume facts with this precedence:
    ///   1. Raw NTFSCore read off the device — full facts incl. NTFS-internal
    ///      fields. Best data, works when unmounted or when we have privileges.
    ///   2. If that fails AND we have a mount point — `statfs` on the mount point.
    ///      No privileges needed; gives capacity/used/free/block-size but leaves
    ///      the NTFS-internal fields nil (they degrade to "Unavailable while
    ///      mounted"). This is the common case for a Finder-mounted NTFS volume,
    ///      whose raw device node is `root:operator 0640`.
    ///   3. If that fails and there's no mount point — rethrow the real error so
    ///      a genuinely unreadable/absent device surfaces it.
    nonisolated static func readFacts(devicePath: String, mountPoint: String?, label: String, isWritable: Bool) async throws -> VolumeFacts {
        do {
            return try await readFactsFromDevice(devicePath: devicePath, label: label, isWritable: isWritable)
        } catch {
            if let mountPoint {
                return try statfsFacts(mountPoint: mountPoint, devicePath: devicePath, label: label, isWritable: isWritable)
            }
            throw error
        }
    }

    /// Full raw read off the device — populates the NTFS-internal fields. Throws
    /// EACCES for a Finder-mounted volume the user can't open.
    nonisolated static func readFactsFromDevice(devicePath: String, label: String, isWritable: Bool) async throws -> VolumeFacts {
        let device = try FileHandleBlockDevice(openingFileAt: devicePath)
        let volume = try await Volume(device: device)
        let stats = try await volume.allocationStats()
        let dirty = try await volume.isDirty()
        let vinfo = try await volume.volumeInformation()
        let boot = volume.boot
        let totalBytes = boot.totalSectors * UInt64(boot.bytesPerSector)
        return VolumeFacts(
            label: label,
            devicePath: devicePath,
            totalBytes: totalBytes,
            freeBytes: stats.freeBytes,
            usedBytes: stats.allocatedBytes,
            bytesPerCluster: volume.bytesPerCluster,
            mftByteOffset: volume.mftByteOffset,
            mftCluster: boot.mftCluster,
            isDirty: dirty,
            ntfsMajorVersion: vinfo.majorVersion,
            ntfsMinorVersion: vinfo.minorVersion,
            isWritable: isWritable
        )
    }

    /// Non-privileged fallback: `statfs()` on the mount point returns total/free
    /// blocks + block size without needing to open the raw device. NTFS-internal
    /// fields stay nil. `f_bavail` (available to non-root) matches Finder's free
    /// number. `f_bsize` is the filesystem block size — the best non-privileged
    /// proxy for cluster size (it is NOT guaranteed to equal the NTFS cluster
    /// size for an fskit mount, but it's the closest we can get without device
    /// access).
    nonisolated static func statfsFacts(mountPoint: String, devicePath: String, label: String, isWritable: Bool) throws -> VolumeFacts {
        var s = statfs()
        guard statfs(mountPoint, &s) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let bsize = UInt64(s.f_bsize)
        let total = UInt64(s.f_blocks) * bsize
        let free  = UInt64(s.f_bavail) * bsize     // available to non-root (matches Finder)
        let used  = total >= free ? total - free : 0
        // Reflect the ACTUAL mount state (macOS mounts NTFS read-only) via the
        // MNT_RDONLY flag, rather than the caller's writable-open capability, so
        // the Permissions row is accurate for a mounted volume. `isWritable`
        // (the passed value) governs the writable device open for Format/Repair.
        let mountIsWritable = (s.f_flags & UInt32(MNT_RDONLY)) == 0
        return VolumeFacts(
            label: label,
            devicePath: devicePath,
            totalBytes: total,
            freeBytes: free,
            usedBytes: used,
            bytesPerCluster: UInt32(s.f_bsize),
            mftByteOffset: nil,
            mftCluster: nil,
            isDirty: nil,
            ntfsMajorVersion: nil,
            ntfsMinorVersion: nil,
            isWritable: mountIsWritable
        )
    }

    nonisolated static func readVerify(devicePath: String) async throws -> VerifyResult {
        let device = try FileHandleBlockDevice(openingFileAt: devicePath)
        let volume = try await Volume(device: device)
        let dirty = try await volume.isDirty()
        let vinfo = try await volume.volumeInformation()
        var problems: [String] = []
        if dirty {
            problems.append("Volume is marked dirty in $Volume — run chkdsk on Windows or ntfsfix.")
        }
        if vinfo.flags.contains(.modifiedByChkdsk) {
            problems.append("Volume was last modified by chkdsk.")
        }
        return VerifyResult(isClean: !dirty, problems: problems)
    }

    /// Open the device writable, format it as NTFS, flush, and release the lock.
    /// DESTRUCTIVE. Device must be unmounted.
    nonisolated static func performFormat(devicePath: String, label: String) async throws -> FormatResult {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: devicePath, lockExclusive: true)
        let size = try await device.size()
        try await Volume.formatNTFS(device: device, deviceSizeBytes: size, label: label, quick: true)
        try await device.synchronize()
        await device.releaseAdvisoryLock()
        return FormatResult(label: label, devicePath: devicePath)
    }

    /// Honest repair: audit + dirty check. Clears the dirty bit only when the
    /// audit is clean; otherwise reports problems without modifying the volume.
    nonisolated static func performRepair(devicePath: String) async throws -> RepairResult {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: devicePath, lockExclusive: true)
        let volume = try await Volume(device: device)
        let dirty = try await volume.isDirty()
        let audit = try await volume.auditAllDataRunlistsAgainstBitmap(maxRecords: 0)

        var problems: [String] = []
        if audit.freeButReferencedClusters > 0 {
            problems.append("\(audit.freeButReferencedClusters) cluster(s) are referenced by a file but marked free in $Bitmap.")
        }
        if audit.outOfRangeClusters > 0 {
            problems.append("\(audit.outOfRangeClusters) cluster reference(s) point outside the volume.")
        }
        if audit.doubleAllocatedClusters > 0 {
            problems.append("\(audit.doubleAllocatedClusters) cluster(s) are claimed by more than one file.")
        }
        if !audit.unreadableRecords.isEmpty {
            problems.append("\(audit.unreadableRecords.count) MFT record(s) could not be read.")
        }

        let result: RepairResult
        if !audit.isClean {
            // Real corruption — do NOT touch the volume; advise chkdsk.
            result = RepairResult(outcome: .problemsFound, problems: problems)
        } else if dirty {
            // Clean structure but flagged dirty: safe to clear the flag.
            try await volume.setDirty(false)
            try await device.synchronize()
            result = RepairResult(outcome: .clearedDirty, problems: [])
        } else {
            result = RepairResult(outcome: .clean, problems: [])
        }
        await device.releaseAdvisoryLock()
        return result
    }

    /// Map any thrown error (including NTFSCore + POSIX permission/IO) to a clear
    /// human message — never crash, never silently swallow.
    nonisolated static func message(for error: Error) -> String {
        if let ntfs = error as? NTFSError {
            switch ntfs {
            case .invalidBootSector:
                return "This volume is not NTFS (invalid boot sector)."
            case .readOnlyDevice:
                return "The device is read-only."
            case let .ioFailure(description):
                // The device open fails because the raw node is root-owned
                // (root:operator 0640) and the GUI runs unprivileged — mounting
                // state doesn't change that, so don't repeat the misleading
                // "run diskutil unmount" hint the low-level layer attaches.
                if description.contains("cannot open") {
                    return "Reading NTFS details needs administrator privileges — the raw device is owned by root. Mounted volumes show capacity via the system; full details require elevated access (e.g. `sudo ntfsctl info`)."
                }
                return "I/O error: \(description)"
            case let .corruptOnDisk(description):
                return "On-disk corruption detected: \(description)"
            case let .unsupportedFeature(description):
                return "Unsupported NTFS feature: \(description)"
            case let .shortRead(expected, got):
                return "Short read (expected \(expected) bytes, got \(got)) — the device may be busy or disconnected."
            default:
                return "NTFS error: \(ntfs)"
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            switch ns.code {
            case Int(EACCES), Int(EPERM):
                return "Permission denied. Reading the raw device requires elevated privileges."
            case Int(EBUSY):
                return "The device is busy. Try ejecting and reconnecting it."
            case Int(ENOENT):
                return "The device could not be found. It may have been disconnected."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
