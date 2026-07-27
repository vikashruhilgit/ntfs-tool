import ArgumentParser
import Foundation
import NTFSCore

/// `ntfsctl tree` — recursive `/usr/bin/tree`-style listing.
///
/// A pure consumer of `NTFSCore.DirectoryWalker`: this file contains rendering
/// only, no descent logic. (`find` is the other consumer of the same walker.)
struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Print a recursive, indented listing of a directory tree.",
        discussion: """
            Renders /usr/bin/tree-style output and finishes with a
            directory/file count summary. Read-only.

            Uses the shared NTFSCore directory walker, so it is cycle-safe (a
            $I30 entry pointing back at an already-visited directory is shown
            once and not followed) and an unreadable subdirectory is reported
            in place while the rest of the tree still prints.

            8.3 (DOS-namespace) aliases are hidden so each file appears once.
            The volume's metafiles ($MFT, $Boot, …) DO appear in a walk of the
            root, exactly as `ntfsctl list /` shows them.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to walk: a path under the volume root (default /), or an MFT record number with --recnum.")
    var target: String = "/"

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    @Option(name: [.customShort("L"), .long], help: "Maximum depth to descend (1 = the target's own children). Default: unlimited.")
    var depth: Int?

    func validate() throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be at least 1 (got \(depth))")
        }
    }

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let start = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)
        let label = recnum ? "#\(start)" : target

        let summary = try await Tree.render(
            source: volume,
            start: start,
            rootLabel: label,
            maxDepth: depth
        ) { print($0) }

        if summary.unreadableDirectories > 0 {
            FileHandle.standardError.write(Data(
                "ntfsctl tree: \(summary.unreadableDirectories) directory/ies could not be read (shown inline above)\n".utf8
            ))
        }
    }

    struct Summary: Equatable {
        var directories = 0
        var files = 0
        var unreadableDirectories = 0

        /// The `2 directories, 3 files` line /usr/bin/tree ends with.
        var line: String {
            "\(directories) director\(directories == 1 ? "y" : "ies"), \(files) file\(files == 1 ? "" : "s")"
        }
    }

    /// Render the tree under `start` into `emit`, one line per call, and return
    /// the counts. Separated from `run()` so tests can drive the real renderer
    /// with a collecting sink instead of scraping stdout.
    ///
    /// Streams: nothing but the current gutter state (one Bool per level) is
    /// retained, so output begins before the walk finishes and memory does not
    /// grow with the tree.
    @discardableResult
    static func render<Source: DirectoryEnumerating>(
        source: Source,
        start: UInt64,
        rootLabel: String,
        maxDepth: Int?,
        emit: (String) -> Void
    ) async throws -> Summary {
        emit(rootLabel)

        var summary = Summary()
        // gutters[i] == "the ancestor at depth i+1 was its parent's last
        // child", which decides whether that level draws "│   " or "    ".
        var gutters: [Bool] = []

        let walker = DirectoryWalker(source: source)
        try await walker.walk(from: start, rootPath: rootLabel, maxDepth: maxDepth) { event in
            switch event {
            case .entry(let node):
                if gutters.count < node.depth {
                    gutters.append(contentsOf: repeatElement(false, count: node.depth - gutters.count))
                } else if gutters.count > node.depth {
                    gutters.removeLast(gutters.count - node.depth)
                }
                gutters[node.depth - 1] = node.isLastSibling

                var label = node.name
                if node.isDirectory {
                    label += "/"
                    summary.directories += 1
                    if node.isRevisitedDirectory { label += "  [already visited, not followed]" }
                } else {
                    summary.files += 1
                }
                emit(gutter(gutters, depth: node.depth) + branch(isLast: node.isLastSibling) + label)

            case .failure(let failure):
                // Render the error where the failed directory's children would
                // have gone. `gutters` still describes that directory's line,
                // which was emitted immediately before this event.
                summary.unreadableDirectories += 1
                emit(
                    gutter(gutters, depth: failure.depth + 1)
                    + branch(isLast: true)
                    + "[unreadable: \(failure.message)]"
                )
            }
        }

        emit("")
        emit(summary.line)
        return summary
    }

    /// The `│   ` / `    ` columns that precede a node's own branch glyph.
    private static func gutter(_ gutters: [Bool], depth: Int) -> String {
        guard depth > 1 else { return "" }
        var out = ""
        for level in 0..<(depth - 1) {
            out += (level < gutters.count && gutters[level]) ? "    " : "│   "
        }
        return out
    }

    private static func branch(isLast: Bool) -> String {
        isLast ? "└── " : "├── "
    }
}
