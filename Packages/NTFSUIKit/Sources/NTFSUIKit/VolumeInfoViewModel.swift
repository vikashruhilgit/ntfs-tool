import Foundation

/// Fully-formatted, render-ready fields for a single volume. Built purely from
/// `VolumeFacts` via `VolumeInfoFormatter` — no SwiftUI, no I/O — so it is unit
/// testable on its own.
public struct VolumeInfoViewModel: Equatable, Sendable {
    public let label: String
    public let devicePath: String
    public let totalDisplay: String
    public let usedDisplay: String
    public let freeDisplay: String
    public let clusterDisplay: String
    public let mftLocationDisplay: String
    public let percentUsed: Double          // 0...1
    public let percentUsedDisplay: String   // "61.6%"
    public let isDirty: Bool
    public let healthStatus: String         // "Clean" / "Dirty"
    public let versionDisplay: String       // "NTFS 3.1"
    public let isWritable: Bool
    public let permissionDisplay: String    // "Read-only" / "Read/Write"

    public init(facts: VolumeFacts) {
        let f = VolumeInfoFormatter.self
        self.label = facts.label
        self.devicePath = facts.devicePath
        self.totalDisplay = f.humanBytes(facts.totalBytes)
        self.usedDisplay = f.humanBytes(facts.usedBytes)
        self.freeDisplay = f.humanBytes(facts.freeBytes)
        self.clusterDisplay = f.clusterSize(facts.bytesPerCluster)
        self.mftLocationDisplay = f.mftLocation(cluster: facts.mftCluster, byteOffset: facts.mftByteOffset)
        self.percentUsed = f.percentUsed(used: facts.usedBytes, total: facts.totalBytes)
        self.percentUsedDisplay = f.percentUsedLabel(used: facts.usedBytes, total: facts.totalBytes)
        self.isDirty = facts.isDirty
        self.healthStatus = f.healthStatus(isDirty: facts.isDirty)
        self.versionDisplay = f.versionLabel(major: facts.ntfsMajorVersion, minor: facts.ntfsMinorVersion)
        self.isWritable = facts.isWritable
        self.permissionDisplay = f.permissionLabel(isWritable: facts.isWritable)
    }
}

/// Result of a "Verify" action, mapped from the `$Volume` dirty flag and any
/// problems surfaced by NTFSCore.
public struct VerifyResult: Equatable, Sendable {
    public let isClean: Bool
    public let problems: [String]
    public let checkedAt: Date

    public init(isClean: Bool, problems: [String], checkedAt: Date = Date()) {
        self.isClean = isClean
        self.problems = problems
        self.checkedAt = checkedAt
    }

    public var summary: String {
        if isClean { return "No problems found — volume is clean." }
        if problems.isEmpty { return "Volume is marked dirty." }
        return problems.joined(separator: "\n")
    }
}
