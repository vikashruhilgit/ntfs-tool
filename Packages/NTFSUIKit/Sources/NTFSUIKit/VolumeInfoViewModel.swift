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
    public let isDirty: Bool?               // nil when NTFS details unavailable
    public let healthStatus: String         // "Clean" / "Dirty" / "Unavailable"
    public let versionDisplay: String       // "NTFS 3.1" / "Unavailable"
    public let isWritable: Bool
    public let permissionDisplay: String    // "Read-only" / "Read/Write"
    /// True when NTFS-internal facts were read from the device; false when only
    /// non-privileged `statfs` numbers are available (mounted read-only).
    public let ntfsDetailsAvailable: Bool

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
        self.ntfsDetailsAvailable = facts.ntfsDetailsAvailable
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

/// Result of a "Format as NTFS" action. The format path lives entirely in
/// `NTFSCore.Volume.formatNTFS`; this value type just carries the outcome the
/// GUI surfaces afterward.
public struct FormatResult: Equatable, Sendable {
    /// The freshly applied volume label.
    public let label: String
    /// BSD device path that was reformatted.
    public let devicePath: String
    public let completedAt: Date

    public init(label: String, devicePath: String, completedAt: Date = Date()) {
        self.label = label
        self.devicePath = devicePath
        self.completedAt = completedAt
    }

    public var summary: String {
        let name = label.isEmpty ? "(no label)" : label
        return "Formatted \(devicePath) as NTFS (\(name)). It can now be mounted read-write."
    }
}

/// Outcome category for the honest "Repair" action. NTFSCore has NO in-place
/// repair: it can detect dirtiness, run a consistency audit, and clear the
/// dirty bit. Real on-disk corruption is reported and the user is advised to
/// run Windows `chkdsk /F` — we never claim to have fixed corruption.
public enum RepairOutcome: Equatable, Sendable {
    /// Audit clean and not dirty — nothing to do.
    case clean
    /// Was dirty with a clean audit; we cleared the `$Volume` dirty flag.
    case clearedDirty
    /// Audit found structural problems. We did NOT modify the volume.
    case problemsFound
}

/// Result of a "Repair" action — the audit verdict plus any problems found.
public struct RepairResult: Equatable, Sendable {
    public let outcome: RepairOutcome
    public let problems: [String]
    public let completedAt: Date

    public init(outcome: RepairOutcome, problems: [String], completedAt: Date = Date()) {
        self.outcome = outcome
        self.problems = problems
        self.completedAt = completedAt
    }

    /// True when the action found nothing wrong or successfully cleared the
    /// dirty bit — i.e. the volume is now in a good state.
    public var isResolved: Bool {
        switch outcome {
        case .clean, .clearedDirty: return true
        case .problemsFound: return false
        }
    }

    public var headline: String {
        switch outcome {
        case .clean:
            return "No problems found — volume is clean."
        case .clearedDirty:
            return "Cleared the dirty flag — the consistency audit was clean."
        case .problemsFound:
            return "Consistency problems found — run Windows chkdsk /F to repair."
        }
    }

    public var summary: String {
        if problems.isEmpty { return headline }
        return ([headline] + problems).joined(separator: "\n")
    }
}
