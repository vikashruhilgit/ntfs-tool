import ArgumentParser
import Foundation
import NTFSCore

/// Pure renderer for `/usr/bin/tree`-style output.
///
/// Deliberately separate from the subcommand and free of any I/O: it turns
/// one `WalkEntry` at a time into one output line, so `tree` never has to
/// buffer the walk. The only state it keeps is one flag per ancestor level
/// ("does this ancestor have more siblings below it?"), which is what
/// decides whether a level draws `│   ` or four spaces.
struct TreeRenderer {
    private(set) var directoryCount = 0
    private(set) var fileCount = 0

    /// `ancestorHasMoreSiblings[i]` covers depth i+1. Sized to the current
    /// depth, never to the size of the tree.
    private var ancestorHasMoreSiblings: [Bool] = []

    mutating func line(for entry: WalkEntry) -> String {
        line(
            name: entry.name,
            isDirectory: entry.isDirectory,
            depth: entry.depth,
            isLastSibling: entry.isLastSibling
        )
    }

    /// Scalar form — the whole renderer is expressible in these four facts,
    /// which keeps it unit-testable without needing a volume or a walker.
    mutating func line(
        name: String,
        isDirectory: Bool,
        depth: Int,
        isLastSibling: Bool
    ) -> String {
        if isDirectory { directoryCount += 1 } else { fileCount += 1 }

        // Trim the flag stack back to this entry's parent level, then extend
        // it with this entry's own "more siblings?" answer for its children.
        let parentLevels = max(0, depth - 1)
        if ancestorHasMoreSiblings.count > parentLevels {
            ancestorHasMoreSiblings.removeSubrange(parentLevels...)
        }

        var prefix = ""
        for level in 0..<parentLevels {
            let hasMore = level < ancestorHasMoreSiblings.count ? ancestorHasMoreSiblings[level] : false
            prefix += hasMore ? "│   " : "    "
        }
        ancestorHasMoreSiblings.append(!isLastSibling)

        let connector = isLastSibling ? "└── " : "├── "
        return prefix + connector + name + (isDirectory ? "/" : "")
    }

    /// The trailing `/usr/bin/tree` summary.
    var summary: String {
        "\(directoryCount) director\(directoryCount == 1 ? "y" : "ies"), "
            + "\(fileCount) file\(fileCount == 1 ? "" : "s")"
    }
}

struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Print a recursive directory tree, /usr/bin/tree style.",
        discussion: """
            Streams a depth-first $I30 walk — the whole tree is never held in
            memory, so this works on volumes with hundreds of thousands of
            files. Ends with a "N directories, M files" summary.

            Uses the same shared NTFSCore directory walker as `find`, so it
            inherits its cycle safety (a directory whose index references an
            ancestor is listed but not re-entered) and its error containment
            (an unreadable subdirectory is reported to stderr and the rest of
            the walk still completes).
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to walk: a path under the volume root (e.g. /Backups), OR an MFT record number. Default: / (root).")
    var target: String = "/"

    @Option(name: [.customShort("L"), .long], help: "Maximum depth to descend. Default: unlimited.")
    var depth: Int?

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let resolved = try await resolveTarget(target, in: volume)

        let walker = DirectoryWalker(
            volume: volume,
            root: resolved.recordNumber,
            basePath: resolved.path,
            maxDepth: depth ?? Int.max
        )

        print(resolved.path)
        var renderer = TreeRenderer()
        var unreadable = 0
        while let event = await walker.next() {
            switch event {
            case .entry(let entry):
                print(renderer.line(for: entry))
            case .error(let error):
                // depth 0 = the walk root itself couldn't be read. That's a
                // usage error, so exit non-zero like `list` does.
                if error.depth == 0 {
                    throw ValidationError("cannot walk \(error.path): \(error.underlying)")
                }
                unreadable += 1
                FileHandle.standardError.write(Data("[unreadable] \(error.message)\n".utf8))
            }
        }

        print("")
        print(renderer.summary + (unreadable > 0 ? ", \(unreadable) unreadable" : ""))
    }
}

/// Shared target resolution for the two walking subcommands: accept either a
/// path under the volume root or a bare MFT record number, and report the
/// canonical path to display alongside it.
func resolveTarget(
    _ target: String,
    in volume: NTFSCore.Volume
) async throws -> (recordNumber: UInt64, path: String) {
    if let recordNumber = UInt64(target) {
        return (recordNumber, recordNumber == 5 ? "/" : "record:\(recordNumber)")
    }
    guard let resolved = try await volume.resolvePath(target) else {
        throw ValidationError("path not found in volume: \(target)")
    }
    let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return (resolved, trimmed.isEmpty ? "/" : "/" + trimmed)
}
