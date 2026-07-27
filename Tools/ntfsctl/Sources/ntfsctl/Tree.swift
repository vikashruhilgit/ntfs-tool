import ArgumentParser
import Foundation
import NTFSCore

/// `ntfsctl tree` — `/usr/bin/tree`-style recursive listing.
///
/// Consumer A of the ONE shared `NTFSCore.DirectoryWalker`. All descent,
/// cycle safety, depth bounding and per-node error containment live in the
/// walker; this file only renders the event stream it produces.
struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Print a directory tree recursively (like /usr/bin/tree).",
        discussion: """
            Walks the volume's $I30 indexes depth-first and renders them with
            box-drawing connectors, finishing with a directory/file count.

            The walk is streamed — nothing accumulates in memory beyond the
            directories on the current path — so whole-volume trees are fine.
            Directory cycles are detected (the repeated directory is marked
            [cycle] and not re-entered) and an unreadable subdirectory is
            reported inline as [error: …] while the rest of the walk finishes.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to walk: a path under the volume root (e.g. /Backups) or an MFT record number. Default: / (root).")
    var target: String = "/"

    @Option(name: [.customShort("d"), .long], help: "Maximum depth to descend. 1 = immediate children only. Default: unlimited.")
    var depth: Int?

    @Flag(name: [.long], help: "Print full paths instead of just entry names.")
    var fullPath: Bool = false

    func validate() throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be at least 1 (got \(depth))")
        }
    }

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let start = try await WalkTarget.resolve(target, volume: volume)

        var out = ""
        let summary = try await Tree.render(
            source: volume,
            startRecordNumber: start.recordNumber,
            rootPath: start.path,
            maxDepth: depth ?? DirectoryWalker<NTFSCore.Volume>.unlimitedDepth,
            fullPath: fullPath
        ) { line in
            out += line
            out += "\n"
            // Flush in chunks so a huge tree streams to stdout instead of
            // being held whole — mirrors the walker's own streaming contract.
            if out.utf8.count >= 1 << 16 {
                FileHandle.standardOutput.write(Data(out.utf8))
                out.removeAll(keepingCapacity: true)
            }
        }
        if !out.isEmpty {
            FileHandle.standardOutput.write(Data(out.utf8))
        }
        if summary.errors > 0 {
            throw ExitCode(1)
        }
    }

    /// Counts reported in the trailing summary line.
    struct Summary: Equatable {
        var directories = 0
        var files = 0
        var errors = 0
    }

    /// Render the tree rooted at `startRecordNumber`, emitting one line at a
    /// time. Separated from `run()` so tests can drive the exact CLI rendering
    /// without capturing stdout.
    @discardableResult
    static func render(
        source: some DirectoryChildSource,
        startRecordNumber: UInt64,
        rootPath: String,
        maxDepth: Int,
        fullPath: Bool = false,
        emit: (String) -> Void
    ) async throws -> Summary {
        var summary = Summary()
        // `verticals[d]` — does the ancestor printed at depth d+1 still have
        // siblings below it? Drives the "│" continuation columns. Bounded by
        // tree depth, not by tree size.
        var verticals: [Bool] = []

        emit(rootPath)

        let walker = DirectoryWalker(source: source)
        try await walker.walk(from: startRecordNumber, rootPath: rootPath, maxDepth: maxDepth) { event in
            switch event {
            case let .entry(node):
                if node.isDirectory { summary.directories += 1 } else { summary.files += 1 }

                if verticals.count >= node.depth {
                    verticals.removeSubrange((node.depth - 1)...)
                }
                let prefix = verticals.map { $0 ? "│   " : "    " }.joined()
                let connector = node.isLastChild ? "└── " : "├── "
                verticals.append(!node.isLastChild)

                var label = fullPath ? node.path : node.name
                if node.isDirectory { label += "/" }
                if node.isCycle { label += "  [cycle: already visited]" }
                if node.stoppedAtDepthLimit { label += "  [depth limit]" }
                emit(prefix + connector + label)

            case let .failure(failure):
                summary.errors += 1
                if failure.depth == 0 {
                    emit("[error: \(failure.reason)]")
                    return
                }
                // Arrives immediately after its directory's own line, so the
                // vertical columns are already correct for that directory's
                // children level.
                let prefix = verticals.map { $0 ? "│   " : "    " }.joined()
                emit(prefix + "└── [error: \(failure.reason)]")
            }
        }

        emit("")
        var parts = ["\(summary.directories) \(summary.directories == 1 ? "directory" : "directories")",
                     "\(summary.files) \(summary.files == 1 ? "file" : "files")"]
        if summary.errors > 0 {
            parts.append("\(summary.errors) \(summary.errors == 1 ? "error" : "errors")")
        }
        emit(parts.joined(separator: ", "))
        return summary
    }
}
