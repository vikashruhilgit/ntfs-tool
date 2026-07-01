import Foundation
import NTFSCore
import Security

/// `NSXPCConnection.auditToken` exists at runtime (it backs `+[NSXPCConnection
/// currentConnection]` validation) but Apple does not declare it in the public
/// SDK header. Expose it through an `@objc` protocol we cast the connection to —
/// the standard, App-Store-safe technique for retrieving the kernel-bound audit
/// token of the peer (a bare PID can be recycled; the audit token cannot).
@objc private protocol XPCConnectionAuditToken {
    var auditToken: audit_token_t { get }
}

// Root LaunchDaemon entry point. Runs as root (installed via SMAppService) so it
// can open the raw NTFS device node — `root:operator 0640` — which the sandboxed,
// unprivileged GUI cannot. It exposes exactly the read paths NTFSCore already
// implements (volume facts + verify) over XPC, and NOTHING else. It contains no
// NTFS logic of its own: every operation delegates to NTFSCore.

// MARK: - The exported object

/// Implements ``NTFSHelperProtocol`` against NTFSCore. Every method opens the
/// device read-only, does the minimal work, JSON-encodes a DTO, and replies.
/// Errors are surfaced as a message string — never a crash (no `fatalError`).
final class HelperService: NSObject, NTFSHelperProtocol {

    /// Sendable reference box so the detached `Task` can store its `(Data?,
    /// String?)` result without capturing mutable locals across the concurrency
    /// boundary. Written once by the Task, read once after `sem.wait()`; the
    /// semaphore provides the happens-before ordering.
    private final class ReplyBox: @unchecked Sendable {
        var payload: Data?
        var errorMessage: String?
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(helperBuildVersion)
    }

    func readVolumeInfo(devicePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        // Bridge the sync XPC reply block to NTFSCore's async actor via a
        // semaphore. We are on an XPC connection's dispatch queue here, so
        // blocking it is fine and keeps the reply strictly ordered.
        let box = ReplyBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let device = try FileHandleBlockDevice(openingFileAt: devicePath)
                let volume = try await Volume(device: device)
                let stats = try await volume.allocationStats()
                let dirty = try await volume.isDirty()
                let vinfo = try await volume.volumeInformation()
                let boot = volume.boot
                let total = boot.totalSectors * UInt64(boot.bytesPerSector)
                let info = HelperVolumeInfo(
                    total: total,
                    free: stats.freeBytes,
                    used: stats.allocatedBytes,
                    bytesPerCluster: volume.bytesPerCluster,
                    mftCluster: boot.mftCluster,
                    mftByteOffset: volume.mftByteOffset,
                    isDirty: dirty,
                    ntfsMajor: vinfo.majorVersion,
                    ntfsMinor: vinfo.minorVersion
                )
                box.payload = try JSONEncoder().encode(info)
            } catch {
                box.errorMessage = HelperService.describe(error)
            }
            sem.signal()
        }
        sem.wait()
        reply(box.payload, box.errorMessage)
    }

    func verify(devicePath: String, withReply reply: @escaping (Data?, String?) -> Void) {
        let box = ReplyBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
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
                let result = HelperVerifyResult(isClean: !dirty, problems: problems)
                box.payload = try JSONEncoder().encode(result)
            } catch {
                box.errorMessage = HelperService.describe(error)
            }
            sem.signal()
        }
        sem.wait()
        reply(box.payload, box.errorMessage)
    }

    /// Human-readable rendering of a thrown error for the reply string.
    static func describe(_ error: Error) -> String {
        if let ntfs = error as? NTFSError {
            return "NTFS error: \(ntfs)"
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return "POSIX error \(ns.code): \(ns.localizedDescription)"
        }
        return error.localizedDescription
    }
}

// MARK: - Connection acceptance + code-signature gate

/// The listener delegate. It authenticates every connecting client against the
/// pinned code-signing requirement BEFORE exporting the interface. A client that
/// isn't the notarized app signed by our team is rejected outright.
final class HelperDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperDelegate.isClientTrusted(newConnection) else {
            NSLog("[NTFSPrivilegedHelper] rejected connection: client failed code-signature check")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: NTFSHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }

    /// Validate the peer's code signature against ``ntfsHelperClientRequirement``
    /// using its audit token. This is the modern, spoof-resistant path: the
    /// audit token is bound to the actual sending process by the kernel, unlike
    /// a bare PID which can be recycled.
    static func isClientTrusted(_ connection: NSXPCConnection) -> Bool {
        // Retrieve the peer's kernel-bound audit token via the private-but-stable
        // `auditToken` property (see XPCConnectionAuditToken above).
        guard let tokenProvider = connection as? XPCConnectionAuditToken else {
            NSLog("[NTFSPrivilegedHelper] connection does not expose auditToken")
            return false
        }
        var token = tokenProvider.auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)

        let attributes: [CFString: Any] = [
            kSecGuestAttributeAudit: tokenData
        ]

        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            [],
            &code
        )
        guard copyStatus == errSecSuccess, let guestCode = code else {
            NSLog("[NTFSPrivilegedHelper] SecCodeCopyGuestWithAttributes failed: \(copyStatus)")
            return false
        }

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(
            ntfsHelperClientRequirement as CFString,
            [],
            &requirement
        )
        guard reqStatus == errSecSuccess, let req = requirement else {
            NSLog("[NTFSPrivilegedHelper] SecRequirementCreateWithString failed: \(reqStatus)")
            return false
        }

        let checkStatus = SecCodeCheckValidity(guestCode, [], req)
        if checkStatus != errSecSuccess {
            NSLog("[NTFSPrivilegedHelper] SecCodeCheckValidity failed: \(checkStatus)")
            return false
        }
        return true
    }
}

// MARK: - Bring-up

/// Helper build version reported over the handshake. Kept in lockstep with the
/// app's short version string by convention.
let helperBuildVersion = "0.1.0"

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: ntfsHelperMachServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
