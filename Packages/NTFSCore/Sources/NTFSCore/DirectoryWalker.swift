import Foundation

/// A single entry produced by ``DirectoryWalker``.
///
/// `path` is the full `/`-joined path of this entry relative to the walk's
/// root label (see ``DirectoryWalker/init(volume:root:rootPath:maxDepth:)``),
/// so a walk started at record 5 with the default empty root label yields
/// `/sub/nested.txt` for a file one level below `/sub`.
public struct WalkEntry {
    /// Full path of the entry, `/`-joined from the walk's root label.
    public let path: String
    /// The entry's own name (no path components).
    public let name: String
    /// MFT record number the entry refers to.
    public let recordNumber: UInt64
    /// Whether the entry is a directory (`$FILE_NAME` index-present bit).
    public let isDirectory: Bool
    /// Depth below the walk root. Children of the root are depth 1.
    public let depth: Int
    /// `true` when this is the last entry in its parent's (DOS-filtered)
    /// `$I30` listing.
    ///
    /// Exposed so renderers such as `ntfsctl tree` can pick `└──` over `├──`
    /// without a lookahead or a descent of their own — the walker's frame
    /// already knows the sibling count.
    public let isLastSibling: Bool
    /// The underlying `$I30` entry, for callers that need size/namespace/etc.
    public let entry: DirectoryEntry
}

/// A per-node failure encountered while walking.
///
/// Emitted instead of being thrown, so one unreadable directory (a bad sector,
/// a corrupt `$INDEX_ROOT`) cannot abort the rest of the walk.
public struct WalkError {
    /// Path of the directory that could not be enumerated.
    public let path: String
    /// MFT record number of that directory.
    public let recordNumber: UInt64
    /// Depth of that directory itself (the walk root is depth 0).
    public let depth: Int
    /// The error thrown by `Volume.enumerate(directory:)`.
    public let underlying: any Error
}

/// One event in a directory walk.
public enum WalkEvent {
    case entry(WalkEntry)
    case error(WalkError)
}

/// Depth-first, pre-order cursor over an NTFS `$I30` directory tree.
///
/// This is the single general-purpose traversal primitive in `NTFSCore`;
/// consumers (`ntfsctl tree`, `ntfsctl find`) drive it and contain no descent
/// logic of their own.
///
/// ## Cursor, not a buffered producer
///
/// ``next()`` is a cursor over an explicit frame stack: it enumerates a
/// directory only when the walk actually reaches it, and it enumerates a
/// directory's children on the call *after* the directory itself was emitted.
/// It is deliberately **not** built on an `AsyncStream` producer task, whose
/// default unbounded buffering would let the producer race ahead and
/// re-accumulate the whole tree in memory.
///
/// ## Memory bound (stated honestly)
///
/// Retained state is **O(sum of the sibling arrays along the current
/// root-to-node path)** — *not* O(depth). `Volume.enumerate(directory:)`
/// returns a fully materialized `[DirectoryEntry]`, so each open frame holds
/// one complete sibling array: walking into a single flat directory of 22,419
/// entries retains one 22,419-element frame for as long as that directory is
/// open. What this does guarantee is that the *whole tree* is never
/// accumulated — sibling arrays are dropped as soon as their frame is
/// exhausted, and events are handed to the caller one at a time. A true
/// O(depth) walker would require a streaming `enumerate`, which does not exist
/// yet.
///
/// ## Cycle and revisit safety
///
/// `$I30` graphs can contain cycles (`Volume.rename` has no ancestor guard, so
/// a directory can be moved inside its own descendant). Every directory record
/// number the walk descends into is recorded in ``visited``; a directory that
/// is already present is still *emitted* as an entry but is never descended
/// into a second time. The walk therefore always terminates and each directory
/// record is enumerated at most once.
///
/// ## Error containment
///
/// ``next()`` never throws. A directory that cannot be enumerated — including
/// the start directory — yields a single ``WalkEvent/error(_:)`` carrying that
/// node's path, record number, depth and the underlying error; the walk then
/// continues with the next sibling.
///
/// ## Usage
///
/// ```swift
/// var walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 3)
/// while let event = await walker.next() {
///     switch event {
///     case .entry(let e): print(e.path)
///     case .error(let e): FileHandle.standardError.write(Data("\(e.path): \(e.underlying)\n".utf8))
///     }
/// }
/// ```
public struct DirectoryWalker {
    /// One open directory on the descent path: its already-materialized
    /// (DOS-filtered) sibling array plus a cursor into it.
    struct Frame {
        /// Path of the directory this frame enumerates.
        let path: String
        /// Depth of the *entries* in this frame (children of the walk root
        /// are depth 1).
        let depth: Int
        let entries: [DirectoryEntry]
        /// Index of the next entry to serve.
        var index: Int = 0
    }

    /// A directory that has been emitted as an entry and still needs to be
    /// enumerated. Deferring the `enumerate` call to the *following*
    /// ``next()`` keeps the cursor from descending ahead of the caller.
    private struct PendingDescent {
        let recordNumber: UInt64
        let path: String
        /// Depth of the directory itself; its children are at `depth + 1`.
        let depth: Int
    }

    private let volume: Volume
    private let rootRecordNumber: UInt64
    private let rootPath: String

    /// Maximum depth of emitted entries. Children of the root are depth 1, so
    /// `maxDepth: 1` emits only the root's immediate children.
    public let maxDepth: Int

    // Internal (not private) so `@testable import NTFSCore` can assert the
    // streaming behaviour — see ``frameDepth``.
    var frames: [Frame] = []
    /// Directory record numbers that have been (or are about to be) descended
    /// into. Seeded with the start record.
    private(set) var visited: Set<UInt64> = []

    private var pending: PendingDescent?
    private var started = false

    /// Number of open frames on the descent stack.
    ///
    /// Test seam for the streaming guarantee: after exactly one ``next()``
    /// call this is 1 (a buffer-then-serve implementation would already have
    /// descended to full depth), and it never exceeds ``maxDepth``.
    var frameDepth: Int { frames.count }

    /// - Parameters:
    ///   - volume: Volume to read `$I30` indexes from.
    ///   - root: MFT record number of the directory to start at (5 is the
    ///     volume root).
    ///   - rootPath: Path label the emitted paths are joined onto. The default
    ///     empty label produces absolute-looking paths such as `/sub/file.txt`.
    ///   - maxDepth: Deepest entry depth to emit. Children of `root` are depth
    ///     1; the default is unbounded.
    public init(
        volume: Volume,
        root: UInt64,
        rootPath: String = "",
        maxDepth: Int = .max
    ) {
        self.volume = volume
        self.rootRecordNumber = root
        self.rootPath = rootPath
        self.maxDepth = maxDepth
        self.visited = [root]
    }

    /// Advance the cursor and return the next event, or `nil` when the walk is
    /// complete.
    ///
    /// Never throws: per-node failures surface as ``WalkEvent/error(_:)``.
    public mutating func next() async -> WalkEvent? {
        if !started {
            started = true
            // Depth is checked *before* enumerating: with `maxDepth < 1` even
            // the root's children are out of bounds, so no read is issued.
            guard maxDepth >= 1 else { return nil }
            do {
                let entries = try await enumerateFiltered(rootRecordNumber)
                frames.append(Frame(path: rootPath, depth: 1, entries: entries))
            } catch {
                // Containment covers the start directory too: emit and finish
                // (`frames` stays empty, so the next call returns nil).
                return .error(WalkError(
                    path: rootPath,
                    recordNumber: rootRecordNumber,
                    depth: 0,
                    underlying: error
                ))
            }
        }

        // Service a descent scheduled by the previous call before serving any
        // further siblings, so the emission order stays depth-first pre-order.
        if let descent = pending {
            pending = nil
            do {
                let entries = try await enumerateFiltered(descent.recordNumber)
                frames.append(Frame(
                    path: descent.path,
                    depth: descent.depth + 1,
                    entries: entries
                ))
            } catch {
                return .error(WalkError(
                    path: descent.path,
                    recordNumber: descent.recordNumber,
                    depth: descent.depth,
                    underlying: error
                ))
            }
        }

        while let top = frames.indices.last {
            guard frames[top].index < frames[top].entries.count else {
                // Frame exhausted — drop its sibling array and resume the
                // parent.
                frames.removeLast()
                continue
            }

            let frame = frames[top]
            let entry = frame.entries[frame.index]
            frames[top].index += 1

            let path = Self.join(frame.path, entry.name)
            let isLastSibling = frame.index == frame.entries.count - 1

            // Schedule the descent (executed on the next call). `depth <
            // maxDepth` is the pre-enumerate bound: the children would land at
            // `depth + 1`. Written as a strict `<` to avoid overflowing when
            // `maxDepth` is `Int.max`.
            if entry.isDirectory,
               frame.depth < maxDepth,
               visited.insert(entry.recordNumber).inserted {
                pending = PendingDescent(
                    recordNumber: entry.recordNumber,
                    path: path,
                    depth: frame.depth
                )
            }

            return .entry(WalkEntry(
                path: path,
                name: entry.name,
                recordNumber: entry.recordNumber,
                isDirectory: entry.isDirectory,
                depth: frame.depth,
                isLastSibling: isLastSibling,
                entry: entry
            ))
        }

        return nil
    }

    /// Enumerate a directory, dropping DOS-namespace aliases.
    ///
    /// Filtering happens here — the single place — so every consumer sees one
    /// entry per file rather than a duplicate for each 8.3 short name, and so
    /// `isLastSibling` is computed against the filtered listing. Mirrors the
    /// `namespace != .dos` filter in `ntfsctl list`.
    private func enumerateFiltered(_ recordNumber: UInt64) async throws -> [DirectoryEntry] {
        try await volume.enumerate(directory: recordNumber)
            .filter { $0.fileName.namespace != .dos }
    }

    private static func join(_ base: String, _ name: String) -> String {
        if base.isEmpty || base == "/" { return "/" + name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}

extension DirectoryWalker: AsyncSequence, AsyncIteratorProtocol {
    public typealias Element = WalkEvent

    /// Convenience `for await` wrapper around the cursor. The iterator is a
    /// copy of the walker, so each call starts a fresh walk.
    public func makeAsyncIterator() -> DirectoryWalker { self }
}
