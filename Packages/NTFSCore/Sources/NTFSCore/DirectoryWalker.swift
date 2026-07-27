import Foundation

/// The single capability the recursive walker needs from a volume: list the
/// children of ONE directory.
///
/// `Volume` conforms (see the extension below), so production callers pass a
/// live volume. Tests substitute in-memory graphs — directory cycles,
/// deliberately unreadable subtrees, and trees far larger than any committed
/// `.img` fixture — that would be impractical or impossible to build on disk.
public protocol DirectoryEnumerating: Sendable {
    /// Children of the directory at `recordNumber`, in `$I30` order.
    func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry]
}

extension Volume: DirectoryEnumerating {}

/// One entry yielded by `DirectoryWalker`, in pre-order (a directory is
/// yielded before its children).
public struct DirectoryWalkNode: Sendable, Equatable {
    /// Full slash-separated path of this entry, rooted at the walk's start
    /// directory (e.g. `/Backups/2026/notes.txt`).
    public let path: String
    /// The `$I30` entry itself.
    public let entry: DirectoryEntry
    /// 1 for a direct child of the walk root, 2 for a grandchild, and so on.
    public let depth: Int
    /// True when this entry is the last of its parent's children. Enough — in
    /// combination with `depth` — for a renderer to draw `tree(1)` gutters
    /// without the walker having to hand out an ancestry array per node.
    public let isLastSibling: Bool
    /// True when this entry is a directory whose contents were deliberately
    /// NOT walked because its MFT record had already been visited — i.e. a
    /// `$I30` cycle or a hard-linked directory. The node is still reported so
    /// consumers can show it; the walk simply does not descend.
    public let isRevisitedDirectory: Bool

    public var name: String { entry.name }
    public var isDirectory: Bool { entry.isDirectory }
    public var recordNumber: UInt64 { entry.recordNumber }
}

/// A subdirectory that could not be read. The walk records one of these and
/// keeps going, rather than aborting the whole traversal.
public struct DirectoryWalkFailure: Sendable, Equatable {
    /// Full path of the directory that failed to open.
    public let path: String
    /// Its MFT record number.
    public let recordNumber: UInt64
    /// Depth of the failing directory (same value its `.entry` event carried).
    public let depth: Int
    /// Human-readable description of the underlying error.
    public let message: String
}

public enum DirectoryWalkEvent: Sendable {
    case entry(DirectoryWalkNode)
    case failure(DirectoryWalkFailure)
}

/// The one recursive `$I30` traversal in the project. `ntfsctl tree` and
/// `ntfsctl find` are both thin consumers of this type — neither implements
/// descent of its own.
///
/// Properties, each covered by a test in `DirectoryWalkerTests`:
///
/// - **Streaming.** Events are handed to `visit` as they are discovered; the
///   walker never builds a whole-tree structure. Live memory is
///   O(depth × largest sibling set) for the frontier — one `enumerate` result
///   per level of the current path — plus 8 bytes per *directory* for the
///   visited set that cycle safety requires. Neither term is O(entries), which
///   is what makes it usable on the 22,419-file corpus. Measured on a
///   349,524-entry synthetic tree: 3.2 MiB resident growth streaming vs
///   204 MiB when the same events are collected into an array.
/// - **Cycle and revisit safe.** Visited *directory* MFT record numbers are
///   tracked, so a `$I30` that references an ancestor (or any already-seen
///   directory) is reported once and not descended.
/// - **Depth bounded.** `maxDepth` is checked BEFORE a directory is
///   enumerated, so bounding the depth also bounds the IO performed.
/// - **Error contained.** An unreadable subdirectory produces a
///   `.failure` event for that node and the walk continues with its siblings.
///
/// Filtering contract: DOS-namespace (8.3) aliases are skipped so each file
/// appears once under its Win32/POSIX name, and the `.`/`..` self-links that
/// NTFS keeps in a root index are skipped. Everything else — including the
/// `$MFT`-and-friends metafiles that live in the root index — is yielded, so
/// a walk agrees with what `ntfsctl list` shows at each level.
public struct DirectoryWalker<Source: DirectoryEnumerating>: Sendable {

    /// MFT record number of the volume root directory.
    public static var rootRecordNumber: UInt64 { 5 }

    private let source: Source

    public init(source: Source) {
        self.source = source
    }

    /// Walk the tree under `rootRecordNumber` in pre-order, handing each event
    /// to `visit` as it is produced.
    ///
    /// - Parameters:
    ///   - rootRecordNumber: directory to start from (5 = volume root).
    ///   - rootPath: path that `rootRecordNumber` corresponds to; yielded
    ///     paths are built from it.
    ///   - maxDepth: deepest level to report, 1 = the start directory's own
    ///     children. `nil` means unlimited. Values < 1 yield nothing.
    ///   - visit: receives every entry and every per-node failure. Throwing
    ///     from it aborts the walk and propagates — that is the supported way
    ///     to stop early.
    ///
    /// Throws only if the *start* directory itself cannot be read (there is no
    /// walk to contain the error into) or if `visit` throws.
    public func walk(
        from rootRecordNumber: UInt64 = 5,
        rootPath: String = "/",
        maxDepth: Int? = nil,
        visit: (DirectoryWalkEvent) async throws -> Void
    ) async throws {
        if let maxDepth, maxDepth < 1 { return }

        // A directory is "visited" the moment we decide to enumerate it. The
        // start directory counts, so a cycle back to the root is caught too.
        var visitedDirectories: Set<UInt64> = [rootRecordNumber]

        let normalizedRoot = Self.normalizeRootPath(rootPath)
        var stack: [Frame] = [
            Frame(
                path: normalizedRoot,
                childDepth: 1,
                children: try await children(of: rootRecordNumber),
                next: 0
            )
        ]

        while let top = stack.indices.last {
            guard stack[top].next < stack[top].children.count else {
                stack.removeLast()
                continue
            }

            let entry = stack[top].children[stack[top].next]
            stack[top].next += 1

            let depth = stack[top].childDepth
            let isLastSibling = stack[top].next == stack[top].children.count
            let path = Self.join(stack[top].path, entry.name)

            guard entry.isDirectory else {
                try await visit(.entry(DirectoryWalkNode(
                    path: path,
                    entry: entry,
                    depth: depth,
                    isLastSibling: isLastSibling,
                    isRevisitedDirectory: false
                )))
                continue
            }

            let firstVisit = visitedDirectories.insert(entry.recordNumber).inserted
            try await visit(.entry(DirectoryWalkNode(
                path: path,
                entry: entry,
                depth: depth,
                isLastSibling: isLastSibling,
                isRevisitedDirectory: !firstVisit
            )))

            // Depth is checked here, before the enumerate — so `--depth N`
            // bounds the IO as well as the output.
            guard firstVisit, maxDepth == nil || depth < maxDepth! else { continue }

            do {
                stack.append(Frame(
                    path: path,
                    childDepth: depth + 1,
                    children: try await children(of: entry.recordNumber),
                    next: 0
                ))
            } catch {
                // Error containment: this subtree is lost, the rest is not.
                try await visit(.failure(DirectoryWalkFailure(
                    path: path,
                    recordNumber: entry.recordNumber,
                    depth: depth,
                    message: Self.describe(error)
                )))
            }
        }
    }

    // MARK: - Internals

    /// One level of the current path: the sibling set being consumed plus a
    /// cursor into it. Only levels on the *current* path are live, which is
    /// what keeps the walk streaming.
    private struct Frame {
        let path: String
        let childDepth: Int
        let children: [DirectoryEntry]
        var next: Int
    }

    /// Children of one directory, with the walker's filtering contract applied.
    private func children(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
        try await source.enumerate(directory: recordNumber).filter {
            $0.fileName.namespace != .dos && $0.name != "." && $0.name != ".."
        }
    }

    private static func normalizeRootPath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        if path.count > 1 && path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func describe(_ error: Error) -> String {
        if let ntfs = error as? NTFSError { return String(describing: ntfs) }
        return error.localizedDescription
    }
}
