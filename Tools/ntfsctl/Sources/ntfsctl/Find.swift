import ArgumentParser
import Foundation
import NTFSCore

/// Glob matcher for entry names.
///
/// Uses `fnmatch(3)` with `FNM_CASEFOLD`: NTFS name lookup is
/// case-insensitive, so `--name '*.JPG'` and `--name '*.jpg'` finding the
/// same files is what matches the filesystem's own semantics (and what
/// `ntfsctl`'s path resolution already does).
struct GlobMatcher {
    let pattern: String

    func matches(_ name: String) -> Bool {
        pattern.withCString { patternPtr in
            name.withCString { namePtr in
                fnmatch(patternPtr, namePtr, FNM_CASEFOLD) == 0
            }
        }
    }
}

enum EntryTypeFilter: String, ExpressibleByArgument, CaseIterable {
    case f
    case d

    func admits(_ entry: WalkEntry) -> Bool {
        switch self {
        case .f: return !entry.isDirectory
        case .d: return entry.isDirectory
        }
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find entries by name pattern anywhere under a directory.",
        discussion: """
            Recursively matches entry names against a glob and prints the
            full path of each match, one per line. Matching is
            case-insensitive, mirroring NTFS name semantics.

            Name matching only — there is no content search and no -exec.

            Uses the same shared NTFSCore directory walker as `tree`, so it
            inherits its cycle safety and error containment: an unreadable
            subdirectory is reported to stderr and the rest of the walk still
            completes.

            EXAMPLES
              ntfsctl find /dev/disk10s1 / --name '*.jpg'
              ntfsctl find /dev/disk10s1 /Backups --name 'IMG_*' --type f --depth 3
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to search under: a path under the volume root, OR an MFT record number. Default: / (root).")
    var target: String = "/"

    @Option(name: [.short, .long], help: "Glob to match entry names against (e.g. '*.jpg'). Default: match everything.")
    var name: String = "*"

    @Option(name: [.customShort("L"), .long], help: "Maximum depth to descend. Default: unlimited.")
    var depth: Int?

    @Option(name: [.short, .long], help: "Restrict matches to files (f) or directories (d). Default: both.")
    var type: EntryTypeFilter?

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

        let matcher = GlobMatcher(pattern: name)
        while let event = await walker.next() {
            switch event {
            case .entry(let entry):
                guard type?.admits(entry) ?? true else { continue }
                guard matcher.matches(entry.name) else { continue }
                print(entry.path)
            case .error(let error):
                // depth 0 = the search root itself couldn't be read.
                if error.depth == 0 {
                    throw ValidationError("cannot search \(error.path): \(error.underlying)")
                }
                FileHandle.standardError.write(Data("[unreadable] \(error.message)\n".utf8))
            }
        }
    }
}
