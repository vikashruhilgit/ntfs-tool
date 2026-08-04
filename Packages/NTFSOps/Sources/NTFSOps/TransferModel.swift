import Foundation

/// What to do when a destination file already exists.
public enum ConflictPolicy: String, Sendable, CaseIterable {
    /// Overwrite the existing destination (the `cp` default).
    case replace
    /// Leave the existing destination untouched and count the source as skipped
    /// (`cp -n` / `--no-clobber`).
    case skip
}

/// Knobs shared by every transfer direction.
public struct TransferOptions: Sendable {
    public var conflict: ConflictPolicy
    /// Cross-device cut: delete each source only AFTER its own copy succeeded.
    /// A skipped or failed source is always preserved.
    public var removeSource: Bool
    /// Streaming chunk size for file content. 1 MiB by default — large enough to
    /// keep USB throughput up, small enough that peak memory is independent of
    /// file size.
    public var chunkSize: Int

    public init(
        conflict: ConflictPolicy = .replace,
        removeSource: Bool = false,
        chunkSize: Int = 1 << 20
    ) {
        self.conflict = conflict
        self.removeSource = removeSource
        self.chunkSize = chunkSize
    }
}

/// A point-in-time snapshot of a running transfer, delivered to the progress
/// callback after each file completes.
///
/// Rates are derived rather than stored so a consumer that samples slowly can
/// still render a smooth rate; `startedAt` is the engine's own start time.
public struct TransferProgress: Sendable {
    public let filesDone: Int
    public let totalFiles: Int
    public let bytesDone: UInt64
    public let totalBytes: UInt64
    /// Name of the file that just completed — for a "Copying <name>…" line.
    public let currentName: String
    public let startedAt: Date

    public init(
        filesDone: Int,
        totalFiles: Int,
        bytesDone: UInt64,
        totalBytes: UInt64,
        currentName: String,
        startedAt: Date
    ) {
        self.filesDone = filesDone
        self.totalFiles = totalFiles
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.currentName = currentName
        self.startedAt = startedAt
    }

    /// Completion in 0...1. A zero-byte total reports 1.0 rather than NaN.
    public var fraction: Double {
        guard totalBytes > 0 else { return 1.0 }
        return min(1.0, Double(bytesDone) / Double(totalBytes))
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    public var bytesPerSecond: Double {
        let e = elapsed
        return e > 0 ? Double(bytesDone) / e : 0
    }

    /// Seconds remaining at the current average rate, or nil when there is not
    /// yet enough signal to estimate (no elapsed time, or nothing left to do).
    public var estimatedSecondsRemaining: Double? {
        let rate = bytesPerSecond
        guard rate > 0, totalBytes > bytesDone else { return nil }
        return Double(totalBytes - bytesDone) / rate
    }
}

/// Why a particular source was not transferred. Skips are non-fatal by design —
/// the transfer continues and reports them at the end.
public enum SkipReason: Sendable, Equatable {
    /// Destination exists and the policy is `.skip`.
    case destinationExists
    /// Source is a symlink / device node / socket — not a regular file.
    case notARegularFile(String)
}

/// Terminal (or, after a cancellation, partial) result of a transfer.
public struct TransferSummary: Sendable {
    public var copiedFiles: Int = 0
    public var copiedBytes: UInt64 = 0
    public var skippedFiles: Int = 0
    /// Sources actually deleted under `removeSource`.
    public var movedFiles: Int = 0
    /// Bytes freed at the source by those deletions.
    public var freedBytes: UInt64 = 0
    public var totalFiles: Int = 0
    public var totalBytes: UInt64 = 0
    /// True when the run stopped early because the task was cancelled. The
    /// counters above are then a partial, accurate account of what did land.
    public var cancelled: Bool = false

    public init() {}
}

/// Result of scanning a source tree before any bytes move — the totals a
/// progress bar needs and the free-space arithmetic the pre-check needs.
public struct TransferPlan: Sendable {
    public let totalFiles: Int
    public let totalBytes: UInt64
    /// What the file data will ACTUALLY consume on the volume: each file's size
    /// rounded up to whole clusters. Never use `totalBytes` for a free-space
    /// check — a tree of small files consumes far more than the sum of sizes.
    public let dataClusters: UInt64

    public init(totalFiles: Int, totalBytes: UInt64, dataClusters: UInt64) {
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.dataClusters = dataClusters
    }
}

/// Errors raised by the engine itself (as opposed to `NTFSError` from the core).
public enum TransferError: Error, LocalizedError, Equatable {
    case insufficientFreeSpace(requiredBytes: UInt64, freeBytes: UInt64, files: Int)
    case destinationIsExistingFile(String)
    case cannotOpenHostFile(String)
    case sourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .insufficientFreeSpace(required, free, files):
            return "Not enough free space: \(files) file(s) need about "
                + "\(ByteFormat.human(required)) once rounded up to whole clusters "
                + "(plus MFT and index overhead), but only \(ByteFormat.human(free)) is free."
        case let .destinationIsExistingFile(path):
            return "A file already exists at \(path) — refusing to replace it with a folder."
        case let .cannotOpenHostFile(path):
            return "Cannot open \(path) for writing."
        case let .sourceNotFound(path):
            return "Source not found: \(path)"
        }
    }
}

/// Byte formatting shared by the CLI's progress lines and the GUI's labels, so
/// the two never drift into different units for the same number.
public enum ByteFormat {
    public static func human(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KiB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MiB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GiB", Double(n) / (1024 * 1024 * 1024))
    }
}
