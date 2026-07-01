import Foundation
import ServiceManagement
import NTFSUIKit

/// App-side façade over the privileged helper daemon. Owns the SMAppService
/// registration lifecycle and the XPC connection, and exposes `async` wrappers
/// that bridge the daemon's reply-block methods.
///
/// The daemon runs as root (installed via SMAppService) and is the only party
/// that can open the raw `root:operator 0640` NTFS device node the sandboxed GUI
/// cannot. This client never touches NTFS itself — it just asks the helper.
@MainActor
public final class PrivilegedHelperClient: ObservableObject {

    /// Errors surfaced to the UI / loader fallback.
    public enum HelperError: LocalizedError {
        case notRegistered
        case connectionInvalid
        case remote(String)
        case decodeFailed
        case emptyReply

        public var errorDescription: String? {
            switch self {
            case .notRegistered:
                return "The privileged helper isn't enabled. Enable it in Settings, then approve it in System Settings ▸ Login Items & Extensions."
            case .connectionInvalid:
                return "The connection to the privileged helper is invalid."
            case let .remote(message):
                return message
            case .decodeFailed:
                return "The privileged helper returned malformed data."
            case .emptyReply:
                return "The privileged helper returned no data."
            }
        }
    }

    /// Mirrors `SMAppService.Status` for display, refreshed by `refreshStatus()`.
    @Published public private(set) var status: SMAppService.Status

    private let service: SMAppService

    public init() {
        self.service = SMAppService.daemon(plistName: ntfsHelperPlistName)
        self.status = service.status
    }

    // MARK: - Registration lifecycle

    /// Re-read the daemon's current status (e.g. after the user approves it in
    /// System Settings).
    public func refreshStatus() {
        status = service.status
    }

    /// Register the daemon. First call typically transitions to
    /// `.requiresApproval` — the user must approve it in
    /// System Settings ▸ Login Items & Extensions.
    public func register() throws {
        try service.register()
        refreshStatus()
    }

    /// Unregister the daemon (removes it as a login item / daemon).
    public func unregister() throws {
        try service.unregister()
        refreshStatus()
    }

    /// A human string for the current status, for the Settings row.
    public var statusDescription: String {
        switch status {
        case .notRegistered:   return "Not installed"
        case .enabled:         return "Enabled"
        case .requiresApproval:return "Awaiting approval in System Settings"
        case .notFound:        return "Not found"
        @unknown default:      return "Unknown"
        }
    }

    // MARK: - XPC connection

    /// Build a fresh privileged XPC connection to the daemon. A new connection
    /// per call keeps lifetime trivial: the reply handler tears it down.
    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: ntfsHelperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: NTFSHelperProtocol.self)
        connection.resume()
        return connection
    }

    // MARK: - Async wrappers

    /// Read volume facts off `devicePath` via the root helper and map the DTO
    /// onto the UI's `VolumeFacts`. `label` / `isWritable` are supplied by the
    /// caller (DiskArbitration-derived) since the helper doesn't know them.
    public func readVolumeFacts(
        devicePath: String,
        label: String,
        isWritable: Bool
    ) async throws -> VolumeFacts {
        let info = try await readVolumeInfo(devicePath: devicePath)
        return VolumeFacts(
            label: label,
            devicePath: devicePath,
            totalBytes: info.total,
            freeBytes: info.free,
            usedBytes: info.used,
            bytesPerCluster: info.bytesPerCluster,
            mftByteOffset: info.mftByteOffset,
            mftCluster: info.mftCluster,
            isDirty: info.isDirty,
            ntfsMajorVersion: info.ntfsMajor,
            ntfsMinorVersion: info.ntfsMinor,
            isWritable: isWritable
        )
    }

    /// Raw DTO read — bridges the reply block to `async`.
    public func readVolumeInfo(devicePath: String) async throws -> HelperVolumeInfo {
        // Fail FAST when the daemon isn't enabled — a `.privileged` XPC call to
        // an unregistered mach service can hang instead of erroring, which would
        // stall the loader before it can fall through to statfs.
        guard status == .enabled else { throw HelperError.notRegistered }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let connection = makeConnection()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: HelperError.remote(error.localizedDescription))
            }) as? NTFSHelperProtocol else {
                connection.invalidate()
                continuation.resume(throwing: HelperError.connectionInvalid)
                return
            }
            proxy.readVolumeInfo(devicePath: devicePath) { payload, errorMessage in
                connection.invalidate()
                if let errorMessage {
                    continuation.resume(throwing: HelperError.remote(errorMessage))
                } else if let payload {
                    continuation.resume(returning: payload)
                } else {
                    continuation.resume(throwing: HelperError.emptyReply)
                }
            }
        }
        do {
            return try JSONDecoder().decode(HelperVolumeInfo.self, from: data)
        } catch {
            throw HelperError.decodeFailed
        }
    }

    /// Verify pass via the root helper. Returns `(isClean, problems)`.
    public func verify(devicePath: String) async throws -> (isClean: Bool, problems: [String]) {
        guard status == .enabled else { throw HelperError.notRegistered }
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let connection = makeConnection()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: HelperError.remote(error.localizedDescription))
            }) as? NTFSHelperProtocol else {
                connection.invalidate()
                continuation.resume(throwing: HelperError.connectionInvalid)
                return
            }
            proxy.verify(devicePath: devicePath) { payload, errorMessage in
                connection.invalidate()
                if let errorMessage {
                    continuation.resume(throwing: HelperError.remote(errorMessage))
                } else if let payload {
                    continuation.resume(returning: payload)
                } else {
                    continuation.resume(throwing: HelperError.emptyReply)
                }
            }
        }
        do {
            let result = try JSONDecoder().decode(HelperVerifyResult.self, from: data)
            return (result.isClean, result.problems)
        } catch {
            throw HelperError.decodeFailed
        }
    }
}
