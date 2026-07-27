import ArgumentParser
import Foundation
import NTFSCore

/// Recursive `/usr/bin/tree`-style renderer for an NTFS directory.
///
/// Contains **no traversal logic of its own** — every descent, depth bound,
/// cycle guard and DOS-alias filter lives in `NTFSCore.DirectoryWalker`. This
/// file only turns the walker's event stream into glyph-prefixed lines.
struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Recursively render a directory tree, /usr/bin/tree style.",
        discussion: """
            Renders the directory as an indented tree and finishes with a
            `N directories, M files` summary counted from the entries actually
            emitted.

            Like `list`, the listing is a faithful view of what is in the
            directory's $I30 index: walking the volume root therefore shows the
            NTFS metafiles ($MFT, $MFTMirr, $Extend, …) and the root's `.`
            self-entry. Nothing is hidden; only DOS 8.3 aliases are collapsed.

            A directory that cannot be read (bad sector, corrupt $INDEX_ROOT)
            is reported as an inline `[error: …]` line and does not abort the
            rest of the render.

            The bare target argument is a PATH. Pass --recnum for the
            MFT-record-number form.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Target directory: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String = "/"

    @Option(name: .long, help: "Maximum number of levels to descend (default: unlimited).")
    var depth: Int?

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    func run() async throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be at least 1, got: \(depth)")
        }
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let rn = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)
        try await Self.emit(
            volume: volume,
            root: rn,
            rootLabel: target,
            maxDepth: depth ?? .max,
            into: { print($0) }
        )
    }

    // MARK: - Rendering

    /// Render the tree rooted at `root`, handing each finished line to `sink`.
    ///
    /// Lines are streamed one at a time and never accumulated into an array —
    /// that would re-buffer at the CLI layer exactly what ``DirectoryWalker``
    /// is careful not to buffer. Tests drive this directly with an
    /// array-appending sink instead of capturing stdout.
    ///
    /// ## What is counted
    ///
    /// The trailing summary counts the entries the walker actually emitted:
    /// every `isDirectory` entry is a directory, everything else is a file.
    /// **No entry is filtered out here.** In particular a walk from record 5
    /// includes the NTFS metafiles and the root's `.` self-entry, because the
    /// walker mirrors a raw `$I30` enumeration (minus DOS aliases) exactly, and
    /// `ntfsctl list` already shows those same entries. The walk root itself is
    /// *not* counted, matching `/usr/bin/tree`.
    ///
    /// ## Error placement
    ///
    /// A ``WalkError`` is rendered as an only-child line one level below the
    /// directory that failed (`error.depth + 1`), so it always uses the
    /// last-sibling glyph `└── `. A start-directory failure arrives at depth 0
    /// with `path` equal to `rootLabel` verbatim, so it lands directly under
    /// the root header line with no prefix.
    ///
    /// - Parameters:
    ///   - volume: Volume to read from.
    ///   - root: MFT record number of the directory to render.
    ///   - rootLabel: Path label printed as the header line and used as the
    ///     walker's path prefix.
    ///   - maxDepth: Deepest level to descend. Children of the root are level 1.
    ///   - sink: Receives each rendered line, without a trailing newline.
    static func emit(
        volume: NTFSCore.Volume,
        root: UInt64,
        rootLabel: String,
        maxDepth: Int,
        into sink: (String) -> Void
    ) async throws {
        sink(rootLabel.isEmpty ? "/" : rootLabel)

        // `lastFlags[i]` is the `isLastSibling` flag of the ancestor at depth
        // `i + 1`. A non-last ancestor keeps its vertical bar alive below it;
        // a last one is drawn over with blanks.
        var lastFlags: [Bool] = []
        var directories = 0
        var files = 0

        var walker = DirectoryWalker(
            volume: volume,
            root: root,
            rootPath: rootLabel,
            maxDepth: maxDepth
        )

        while let event = await walker.next() {
            switch event {
            case .entry(let entry):
                sink(
                    prefix(for: entry.depth, lastFlags: lastFlags)
                        + glyph(isLastSibling: entry.isLastSibling)
                        + entry.name
                        + (entry.isDirectory ? "/" : "")
                )
                // Record this entry's flag at its own depth so its children
                // know whether to draw a bar through this column.
                lastFlags = Array(lastFlags.prefix(entry.depth - 1)) + [entry.isLastSibling]
                if entry.isDirectory { directories += 1 } else { files += 1 }

            case .error(let error):
                let depth = error.depth + 1
                sink(
                    prefix(for: depth, lastFlags: lastFlags)
                        + glyph(isLastSibling: true)
                        + "[error: \(error.underlying)]"
                )
            }
        }

        sink("")
        sink("\(directories) directories, \(files) files")
    }

    /// Ancestor columns for a line at `depth` (1-based). Ancestors deeper than
    /// the line itself are ignored, which also makes a `WalkError` at depth 0
    /// (empty `lastFlags`) render with no prefix at all.
    private static func prefix(for depth: Int, lastFlags: [Bool]) -> String {
        lastFlags.prefix(max(depth - 1, 0))
            .map { $0 ? "    " : "│   " }
            .joined()
    }

    private static func glyph(isLastSibling: Bool) -> String {
        isLastSibling ? "└── " : "├── "
    }
}
