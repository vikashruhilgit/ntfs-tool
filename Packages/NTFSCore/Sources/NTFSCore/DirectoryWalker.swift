import Foundation

/// One entry yielded by a `DirectoryWalker`.
///
/// `path` is the full slash-separated path from the walk's base path, so a
/// consumer never has to re-join components itself. `depth` counts levels
/// below the walk root — the root's own children are at depth 1.
///
/// `isLastSibling` is what lets a `/usr/bin/tree`-style renderer draw the
/// `└──` vs `├──` connector without buffering a directory's children: the
/// walker already holds the sibling array for the current frame, so it can
/// answer the question the consumer would otherwise have to accumulate for.
public struct WalkEntry: Sendable, Equatable {
    public let path: String
    public let entry: DirectoryEntry
    public let depth: Int
    public let isLastSibling: Bool

    public var name: String { entry.name }
    public var isDirectory: Bool { entry.isDirectory }

    public init(path: String, entry: DirectoryEntry, depth: Int, isLastSibling: Bool) {
        self.path = path
        self.entry = entry
        self.depth = depth
        self.isLastSibling = isLastSibling
    }
}

/// A directory that could not be read. The walk does NOT abort — this is
/// reported for the one node and traversal continues with its siblings.
///
/// `depth == 0` is special: it means the *walk root itself* was unreadable,
/// which is a usage error (bad path / not a directory) rather than one
/// damaged subtree. Consumers map that to a non-zero exit, matching what
/// `ntfsctl list` already does for an unresolvable path.
public struct WalkError: Sendable, Equatable {
    public let path: String
    public let recordNumber: UInt64
    public let depth: Int
    public let underlying: NTFSError

    public init(path: String, recordNumber: UInt64, depth: Int, underlying: NTFSError) {
        self.path = path
        self.recordNumber = recordNumber
        self.depth = depth
        self.underlying = underlying
    }

    /// Human-readable form, derived from the typed error rather than stored
    /// in place of it.
    public var message: String {
        "\(path) (record \(recordNumber)): \(underlying)"
    }
}

/// One step of a walk: either an entry or a contained per-node failure.
public enum WalkEvent: Sendable, Equatable {
    case entry(WalkEntry)
    case error(WalkError)
}

/// Recursive `$I30` directory walker — the single traversal implementation
/// in NTFSCore. `ntfsctl tree` and `ntfsctl find` are both thin consumers of
/// it; neither re-implements descent.
///
/// **Pull-based, not callback-based.** Consumers drive it:
///
///     let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 3)
///     while let event = await walker.next() { ... }
///
/// This shape is deliberate. `Volume` is an `actor`, so a `walk(onEvent:)`
/// callback would have to cross an actor boundary — which under Swift 6
/// strict concurrency forces `sending`/`@Sendable` on the closure and makes
/// a renderer that mutates captured state (indent flags, running counts)
/// illegal. Pulling instead keeps every bit of consumer state in the
/// consumer's own async function, and moves only `Sendable` values across
/// the boundary (`DirectoryEntry` and `NTFSError` already conform).
///
/// Guarantees:
/// - **Streaming.** Only the frames along the current root-to-node path are
///   retained — memory is O(depth × siblings-per-level), never O(total
///   entries). The whole tree is never materialized.
/// - **Cycle/revisit safe.** Directory record numbers already descended into
///   are tracked; a `$I30` that references an ancestor is yielded as an
///   entry but not descended a second time, so a cycle terminates.
/// - **Depth bounded.** `maxDepth` is checked *before* descending, so an
///   out-of-bounds subtree is never read at all.
/// - **Error contained.** An unreadable directory produces one `.error`
///   event; the walk continues.
///
/// Order is pre-order DFS in `$I30` order, which is already NTFS
/// `COLLATION_FILE_NAME` order — the walker does not re-sort.
public actor DirectoryWalker {

    /// One level of the descent: the directory's children plus a cursor into
    /// them. This stack — and only this stack — is the walker's retained
    /// state, which is what makes the walk streaming rather than accumulating.
    private struct Frame {
        let path: String
        let entries: [DirectoryEntry]
        var cursor: Int
        let depth: Int
    }

    private let volume: Volume
    private let rootRecordNumber: UInt64
    private let basePath: String
    private let maxDepth: Int

    private var stack: [Frame] = []
    private var visited: Set<UInt64> = []
    private var started = false
    private var finished = false

    /// An error discovered while descending. Delivered on the pull *after*
    /// the entry that triggered it, so the entry itself is never swallowed.
    private var pendingError: WalkError?

    /// Test seam (`@testable`): current frame-stack depth. Read between
    /// `next()` calls, when the walker is quiescent, it proves the streaming
    /// property — after the first `next()` on a deep tree this is 1, and it
    /// never exceeds `maxDepth`.
    internal var frameDepth: Int { stack.count }

    /// - Parameters:
    ///   - volume: the volume to read from.
    ///   - root: MFT record number of the directory to start at (5 = root).
    ///   - basePath: path prefix the yielded paths are built on. Defaults to `/`.
    ///   - maxDepth: maximum depth below the root to descend. Depth 1 = the
    ///     root's own children. Defaults to unbounded.
    public init(
        volume: Volume,
        root: UInt64,
        basePath: String = "/",
        maxDepth: Int = Int.max
    ) {
        self.volume = volume
        self.rootRecordNumber = root
        self.basePath = basePath
        self.maxDepth = maxDepth
    }

    /// Advance the walk by one event. Returns `nil` when the walk is done.
    ///
    /// Never throws: a per-node failure is returned as `.error` so the caller
    /// can report it and keep going. A failure at `depth == 0` means the walk
    /// root itself was unreadable.
    public func next() async -> WalkEvent? {
        if let error = pendingError {
            pendingError = nil
            return .error(error)
        }
        if finished { return nil }

        if !started {
            started = true
            // maxDepth < 1 means "don't even list the root's children".
            guard maxDepth >= 1 else {
                finished = true
                return nil
            }
            visited.insert(rootRecordNumber)
            switch await readDirectory(recordNumber: rootRecordNumber, path: basePath) {
            case .success(let entries):
                stack.append(Frame(path: basePath, entries: entries, cursor: 0, depth: 1))
            case .failure(let error):
                finished = true
                return .error(WalkError(
                    path: basePath,
                    recordNumber: rootRecordNumber,
                    depth: 0,
                    underlying: error
                ))
            }
        }

        while var frame = stack.last {
            guard frame.cursor < frame.entries.count else {
                stack.removeLast()
                continue
            }

            let entry = frame.entries[frame.cursor]
            frame.cursor += 1
            let isLast = frame.cursor == frame.entries.count
            stack[stack.count - 1] = frame

            let childPath = Self.join(frame.path, entry.name)
            let event = WalkEvent.entry(WalkEntry(
                path: childPath,
                entry: entry,
                depth: frame.depth,
                isLastSibling: isLast
            ))

            // Descend only if it's a directory, we're allowed one more level,
            // and we haven't been here before (cycle/revisit safety).
            let childDepth = frame.depth + 1
            if entry.isDirectory,
               childDepth <= maxDepth,
               visited.insert(entry.recordNumber).inserted {
                switch await readDirectory(recordNumber: entry.recordNumber, path: childPath) {
                case .success(let children):
                    stack.append(Frame(path: childPath, entries: children, cursor: 0, depth: childDepth))
                case .failure(let error):
                    // Error containment: the unreadable subdirectory is
                    // reported for that node only. We still yield the entry
                    // itself (it exists in the parent's index) — the error
                    // event follows on the next pull.
                    pendingError = WalkError(
                        path: childPath,
                        recordNumber: entry.recordNumber,
                        depth: childDepth,
                        underlying: error
                    )
                }
            }

            return event
        }

        finished = true
        return nil
    }

    // MARK: - Internals

    private func readDirectory(
        recordNumber: UInt64,
        path: String
    ) async -> Result<[DirectoryEntry], NTFSError> {
        do {
            let entries = try await volume.enumerate(directory: recordNumber)
            // Skip DOS-namespace 8.3 aliases so names don't double up, and
            // skip any self-referential "." entry.
            return .success(entries.filter {
                $0.fileName.namespace != .dos && $0.name != "."
            })
        } catch let error as NTFSError {
            return .failure(error)
        } catch {
            return .failure(.corruptOnDisk(description: "\(path): \(error)"))
        }
    }

    private static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
