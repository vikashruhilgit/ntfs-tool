import Foundation

// This file is compiled into BOTH the privileged-helper daemon target AND the
// containing app target. It is the ONLY shared surface between them: the XPC
// protocol plus the Codable DTOs marshalled across the connection. Keep it free
// of any NTFSCore / SwiftUI / AppKit imports so both sides can compile it in
// isolation.

/// The XPC service label / mach-service name / helper bundle identifier. Pinned
/// in exactly one place so the daemon listener, the app's `NSXPCConnection`, and
/// the `SMAppService.daemon(plistName:)` bring-up can never drift apart.
public let ntfsHelperMachServiceName = "com.ntfs-tool.NTFSMountManager.PrivilegedHelper"

/// The LaunchDaemon plist filename embedded at
/// `Contents/Library/LaunchDaemons/` and passed to `SMAppService.daemon`.
public let ntfsHelperPlistName = "com.ntfs-tool.NTFSMountManager.PrivilegedHelper.plist"

/// The code-signing requirement the daemon evaluates against every connecting
/// client before accepting it. Pins the app's identifier AND the signing team
/// (OU), so a differently-signed process cannot talk to the root helper.
public let ntfsHelperClientRequirement =
    #"anchor apple generic and identifier "com.ntfs-tool.NTFSMountManager" and certificate leaf[subject.OU] = "JT8YU25ABP""#

// MARK: - DTOs (JSON-marshalled across XPC)

/// Small Codable snapshot of a volume's facts, produced by the root helper by
/// reading the raw device directly. The app maps this onto its own
/// `VolumeFacts` display model. All fields are plain scalars so the JSON is
/// trivially forward/backward compatible.
public struct HelperVolumeInfo: Codable, Sendable, Equatable {
    public var total: UInt64
    public var free: UInt64
    public var used: UInt64
    public var bytesPerCluster: UInt32
    public var mftCluster: UInt64
    public var mftByteOffset: UInt64
    public var isDirty: Bool
    public var ntfsMajor: UInt8
    public var ntfsMinor: UInt8

    public init(
        total: UInt64,
        free: UInt64,
        used: UInt64,
        bytesPerCluster: UInt32,
        mftCluster: UInt64,
        mftByteOffset: UInt64,
        isDirty: Bool,
        ntfsMajor: UInt8,
        ntfsMinor: UInt8
    ) {
        self.total = total
        self.free = free
        self.used = used
        self.bytesPerCluster = bytesPerCluster
        self.mftCluster = mftCluster
        self.mftByteOffset = mftByteOffset
        self.isDirty = isDirty
        self.ntfsMajor = ntfsMajor
        self.ntfsMinor = ntfsMinor
    }
}

/// Result of the helper's verify pass: the clean/dirty verdict plus any
/// human-readable problem strings.
public struct HelperVerifyResult: Codable, Sendable, Equatable {
    public var isClean: Bool
    public var problems: [String]

    public init(isClean: Bool, problems: [String]) {
        self.isClean = isClean
        self.problems = problems
    }
}

// MARK: - XPC protocol

/// The interface the root daemon exports and the app consumes. Every method is
/// XPC-compatible: reply-block signatures carrying only property-list / `Data`
/// types (the DTOs travel as JSON `Data`; failures travel as an optional error
/// `String`). No `async` here — `NSXPCInterface` requires reply-block form.
@objc public protocol NTFSHelperProtocol {
    /// Returns the helper's build version, for a liveness / handshake probe.
    func helperVersion(withReply reply: @escaping (String) -> Void)

    /// Reads volume facts off `devicePath` as root. On success replies
    /// `(json, nil)` where `json` is a JSON-encoded ``HelperVolumeInfo``; on
    /// failure replies `(nil, message)`.
    func readVolumeInfo(devicePath: String, withReply reply: @escaping (Data?, String?) -> Void)

    /// Runs the verify pass off `devicePath` as root. On success replies
    /// `(json, nil)` where `json` is a JSON-encoded ``HelperVerifyResult``; on
    /// failure replies `(nil, message)`.
    func verify(devicePath: String, withReply reply: @escaping (Data?, String?) -> Void)
}
