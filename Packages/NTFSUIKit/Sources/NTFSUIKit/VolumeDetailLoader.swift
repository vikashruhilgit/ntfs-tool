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

    /// The BSD device path this loader reads, e.g. `/dev/disk6s1`.
    public let devicePath: String
    /// Label to surface (DiskArbitration-derived).
    public let label: String
    /// Whether the underlying mount is writable (read-only today).
    public let isWritable: Bool

    @Published public private(set) var info: LoadState<VolumeInfoViewModel> = .idle
    @Published public private(set) var verify: LoadState<VerifyResult> = .idle

    /// Injection seam so unit tests can drive the state machine without a real
    /// device. Production leaves these `nil` and the real NTFSCore path runs.
    private let factsProvider: (@Sendable () async throws -> VolumeFacts)?
    private let verifyProvider: (@Sendable () async throws -> VerifyResult)?

    public init(
        devicePath: String,
        label: String,
        isWritable: Bool,
        factsProvider: (@Sendable () async throws -> VolumeFacts)? = nil,
        verifyProvider: (@Sendable () async throws -> VerifyResult)? = nil
    ) {
        self.devicePath = devicePath
        self.label = label
        self.isWritable = isWritable
        self.factsProvider = factsProvider
        self.verifyProvider = verifyProvider
    }

    /// Load volume facts via NTFSCore and map to the display view-model.
    public func load() async {
        info = .loading
        do {
            let facts: VolumeFacts
            if let provider = factsProvider {
                facts = try await provider()
            } else {
                facts = try await Self.readFacts(devicePath: devicePath, label: label, isWritable: isWritable)
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

    // MARK: - Real NTFSCore reads (run off the main actor)

    nonisolated static func readFacts(devicePath: String, label: String, isWritable: Bool) async throws -> VolumeFacts {
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
