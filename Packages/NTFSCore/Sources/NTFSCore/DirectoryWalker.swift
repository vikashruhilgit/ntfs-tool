import Foundation

/// The single recursive `$I30` traversal in NTFSCore.
///
/// Every recursive-directory consumer (`ntfsctl tree`, `ntfsctl find`) drives
/// THIS walker — none of them re-implement descent. The walker is deliberately
/// tiny and source-agnostic so it can be tested against both a real `Volume`
/// and a synthetic in-memory tree (cycles, unreadable nodes, huge fan-outs)
/// that would be impractical to forge on a disk image.
///
/// Design constraints (see `docs/backlog/pending-followups/03-tree-and-find.md`):
///
///  - **Cycle / revisit safety.** Visited *directory* MFT record numbers are
///    tracked; a directory whose `$I30` points back at an ancestor (or at any
///    already-expanded directory) is reported once with `isCycle == true` and
///    never descended a second time. Files are NOT tracked — hard links to the
///    same `$DATA` are legitimately reachable under several names.
///  - **Depth bound.** `maxDepth` is checked BEFORE the child read, so a
///    depth-limited walk never pays the I/O for the level it will not show.
///  - **Streaming.** State is one frame per level of the CURRENT path (the
///    children of each open directory plus a cursor). Nothing accumulates
///    across siblings, so peak memory scales with depth × fan-out, not with
///    the size of the tree.
///  - **Error containment.** A directory whose children cannot be read yields
///    a `.failure` event for that node and the walk continues with its
///    siblings.

/// Anything that can list the children of a directory by MFT record number.
/// `Volume` conforms below; tests supply synthetic trees.
public protocol DirectoryChildSource: Sendable {
    func directoryChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry]
}

extension Volume: DirectoryChildSource {
    /// `$I30` children of `recordNumber`, in on-disk collation order.
    public func directoryChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
        try await enumerate(directory: recordNumber)
    }
}

/// One entry discovered by the walk.
public struct WalkedNode: Sendable, Equatable {
    /// Full path from the walk root, e.g. `/gallery/Android/IMG_1.jpg`.
    public let path: String
    /// Path of the directory that contains this entry.
    public let parentPath: String
    /// MFT record number of the containing directory.
    public let parentRecordNumber: UInt64
    /// 1 for a direct child of the walk root, 2 for a grandchild, …
    public let depth: Int
    public let entry: DirectoryEntry
    /// True when this is the final entry of its parent's `$I30` listing.
    /// Lets a renderer draw box-drawing connectors without buffering siblings.
    public let isLastChild: Bool
    /// A directory that was NOT descended into because its record number had
    /// already been expanded elsewhere in this walk (cycle / revisit guard).
    public let isCycle: Bool
    /// A directory that was NOT descended into because `maxDepth` was reached.
    public let stoppedAtDepthLimit: Bool

    public var name: String { entry.name }
    public var recordNumber: UInt64 { entry.recordNumber }
    public var isDirectory: Bool { entry.isDirectory }
    public var size: UInt64 { entry.fileName.realSize }
}

/// A directory whose children could not be read. The walk continues; this is
/// reported for the offending node only.
public struct WalkFailure: Sendable, Equatable {
    /// Path of the directory that could not be read.
    public let path: String
    public let recordNumber: UInt64
    /// Depth of the directory itself (0 = the walk root).
    public let depth: Int
    /// Human-readable reason (the underlying error's description).
    public let reason: String
}

/// Streamed walk output. Consumers see each event exactly once, in
/// depth-first pre-order; a `.failure` for a directory always arrives
/// immediately after that directory's own `.entry`.
public enum WalkEvent: Sendable, Equatable {
    case entry(WalkedNode)
    case failure(WalkFailure)
}

public struct DirectoryWalker<Source: DirectoryChildSource>: Sendable {

    /// Pass as `maxDepth` for an unbounded walk.
    public static var unlimitedDepth: Int { Int.max }

    private let source: Source

    public init(source: Source) {
        self.source = source
    }

    /// One frame per open directory on the current path — this is the whole
    /// of the walker's live state.
    private struct Frame {
        let path: String
        let recordNumber: UInt64
        /// Depth that entries in `children` will be reported at.
        let childDepth: Int
        let children: [DirectoryEntry]
        var cursor: Int
    }

    /// Depth-first pre-order walk of `startRecordNumber`'s subtree.
    ///
    /// - Parameters:
    ///   - startRecordNumber: directory to walk (5 = volume root).
    ///   - rootPath: path label the emitted paths are built from. `/` for the
    ///     volume root; pass the resolved absolute path when walking a subtree
    ///     so emitted paths stay volume-absolute.
    ///   - maxDepth: deepest level to report. 1 = the start directory's own
    ///     children only. Checked before descending, so a directory sitting at
    ///     `maxDepth` is reported but never enumerated.
    ///   - onEvent: invoked for every entry and every per-node failure, in
    ///     traversal order. Throwing from it aborts the walk (the error
    ///     propagates to the caller).
    public func walk(
        from startRecordNumber: UInt64 = 5,
        rootPath: String = "/",
        maxDepth: Int = Int.max,
        onEvent: (WalkEvent) async throws -> Void
    ) async throws {
        guard maxDepth >= 1 else { return }

        let root = Self.normalizeRoot(rootPath)

        // The start directory is pre-marked visited so a child pointing back
        // at it is caught by the same guard as any other revisit.
        var visitedDirectories: Set<UInt64> = [startRecordNumber]

        let rootChildren: [DirectoryEntry]
        do {
            rootChildren = try await canonicalChildren(of: startRecordNumber)
        } catch {
            // The walk root itself is unreadable: report and stop — there is
            // nothing else to contain the error to.
            try await onEvent(.failure(WalkFailure(
                path: root,
                recordNumber: startRecordNumber,
                depth: 0,
                reason: Self.describe(error)
            )))
            return
        }

        var stack: [Frame] = [Frame(
            path: root,
            recordNumber: startRecordNumber,
            childDepth: 1,
            children: rootChildren,
            cursor: 0
        )]

        while let top = stack.indices.last {
            guard stack[top].cursor < stack[top].children.count else {
                stack.removeLast()   // frame exhausted — its children are freed here
                continue
            }
            let entry = stack[top].children[stack[top].cursor]
            stack[top].cursor += 1
            let isLastChild = stack[top].cursor == stack[top].children.count

            let depth = stack[top].childDepth
            let parentPath = stack[top].path
            let parentRecordNumber = stack[top].recordNumber
            let path = Self.join(parentPath, entry.name)

            var isCycle = false
            var stoppedAtDepthLimit = false
            var children: [DirectoryEntry]?
            var failure: WalkFailure?

            if entry.isDirectory {
                if visitedDirectories.contains(entry.recordNumber) {
                    isCycle = true
                } else if depth >= maxDepth {
                    stoppedAtDepthLimit = true
                } else {
                    // Marked visited BEFORE the read, so a directory that
                    // fails to open is not retried (and re-reported) at every
                    // other place it is linked from.
                    visitedDirectories.insert(entry.recordNumber)
                    do {
                        children = try await canonicalChildren(of: entry.recordNumber)
                    } catch {
                        failure = WalkFailure(
                            path: path,
                            recordNumber: entry.recordNumber,
                            depth: depth,
                            reason: Self.describe(error)
                        )
                    }
                }
            }

            try await onEvent(.entry(WalkedNode(
                path: path,
                parentPath: parentPath,
                parentRecordNumber: parentRecordNumber,
                depth: depth,
                entry: entry,
                isLastChild: isLastChild,
                isCycle: isCycle,
                stoppedAtDepthLimit: stoppedAtDepthLimit
            )))
            if let failure {
                try await onEvent(.failure(failure))
            }
            if let children {
                stack.append(Frame(
                    path: path,
                    recordNumber: entry.recordNumber,
                    childDepth: depth + 1,
                    children: children,
                    cursor: 0
                ))
            }
        }
    }

    /// Children with DOS-namespace 8.3 aliases dropped, so a name never
    /// appears twice. Matches what `ntfsctl list` shows.
    private func canonicalChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
        try await source.directoryChildren(of: recordNumber)
            .filter { $0.fileName.namespace != .dos }
    }

    private static func normalizeRoot(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "/" : "/" + trimmed
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    private static func describe(_ error: any Error) -> String {
        if let ntfs = error as? NTFSError {
            switch ntfs {
            case let .invalidBootSector(reason): return "invalid boot sector: \(reason)"
            case let .shortRead(expected, got): return "short read (expected \(expected), got \(got))"
            case let .ioFailure(description): return "I/O failure: \(description)"
            case let .unsupportedAttribute(typeCode):
                return String(format: "unsupported attribute type 0x%08X", typeCode)
            case let .unsupportedFeature(description): return "unsupported: \(description)"
            case let .corruptOnDisk(description): return "corrupt: \(description)"
            case .readOnlyDevice: return "device is read-only"
            case let .outOfSpace(requested, free):
                return "out of space (requested \(requested) clusters, \(free) free)"
            }
        }
        return String(describing: error)
    }
}

extension Volume {
    /// Reconstruct the volume-absolute path of `recordNumber` by walking
    /// `$FILE_NAME.parentRecordNumber` up to the root (record 5).
    ///
    /// This is an UPWARD parent-chain walk, not a tree traversal — it does not
    /// duplicate `DirectoryWalker`. It exists so `tree` / `find` can print
    /// volume-absolute paths even when the target was given as a record
    /// number. Returns nil if the chain is broken (no `$FILE_NAME`) or loops.
    public func absolutePath(of recordNumber: UInt64) async throws -> String? {
        if recordNumber == 5 { return "/" }
        var components: [String] = []
        var current = recordNumber
        var seen: Set<UInt64> = []
        while current != 5 {
            guard seen.insert(current).inserted else { return nil }  // parent-chain loop
            let record = try await mft().record(at: current)
            let attrs = try record.attributes()
            // Prefer the Win32 long name over an 8.3 DOS alias.
            let fileNames = attrs
                .filter { $0.type == .fileName }
                .compactMap { attr -> FileName? in
                    guard case let .resident(bytes, _) = attr.value else { return nil }
                    return try? FileName.parse(bytes)
                }
            guard let fn = fileNames.first(where: { $0.namespace != .dos }) ?? fileNames.first else {
                return nil
            }
            components.append(fn.name)
            current = fn.parentRecordNumber
        }
        return "/" + components.reversed().joined(separator: "/")
    }
}
