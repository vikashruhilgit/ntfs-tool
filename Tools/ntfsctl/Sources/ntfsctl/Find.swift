import ArgumentParser
import Foundation
import NTFSCore

/// `ntfsctl find` — locate entries by name across a volume.
///
/// Consumer B of the ONE shared `NTFSCore.DirectoryWalker`. Like `tree`, it
/// contains no traversal logic of its own: it filters the walker's event
/// stream and prints paths.
struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find entries by name pattern anywhere under a directory.",
        discussion: """
            Recursively walks $I30 indexes and prints the full path of every
            entry whose NAME matches --name (a shell glob: * ? [abc] [a-z]
            [!abc]). Matching is case-insensitive by default because NTFS
            itself is; pass --case-sensitive for exact matching.

            Name matching only — there is no content search and no -exec.
            Errors reading a subdirectory go to stderr and the walk continues;
            the exit status is 1 if any subdirectory was unreadable.

            Examples:
              ntfsctl find /dev/disk4s1 --name '*.jpg'
              ntfsctl find backup.img /gallery --name 'IMG_00*' --type f
              ntfsctl find backup.img --type d --depth 2
            """
    )

    enum EntryKind: String, ExpressibleByArgument, CaseIterable {
        case f   // regular files
        case d   // directories
    }

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to search under: a path (e.g. /Backups) or an MFT record number. Default: / (root).")
    var target: String = "/"

    @Option(name: [.short, .long], help: "Glob matched against each entry NAME (not the path). Default: match everything.")
    var name: String?

    @Option(name: [.customShort("d"), .long], help: "Maximum depth to descend. 1 = immediate children only. Default: unlimited.")
    var depth: Int?

    @Option(name: [.short, .long], help: "Restrict results by kind: f (files) or d (directories).")
    var type: EntryKind?

    @Flag(name: [.long], help: "Match --name case-sensitively (default: case-insensitive, matching NTFS semantics).")
    var caseSensitive: Bool = false

    func validate() throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be at least 1 (got \(depth))")
        }
    }

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let start = try await WalkTarget.resolve(target, volume: volume)

        let result = try await Find.search(
            source: volume,
            startRecordNumber: start.recordNumber,
            rootPath: start.path,
            pattern: name,
            kind: type,
            caseSensitive: caseSensitive,
            maxDepth: depth ?? DirectoryWalker<NTFSCore.Volume>.unlimitedDepth,
            onMatch: { print($0) },
            onError: { FileHandle.standardError.write(Data(("ntfsctl find: " + $0 + "\n").utf8)) }
        )
        if result.errors > 0 {
            throw ExitCode(1)
        }
    }

    struct Result: Equatable {
        var matches = 0
        var errors = 0
    }

    /// Walk and report matching paths. Split out of `run()` so tests exercise
    /// the real matching/filtering path without capturing stdout.
    @discardableResult
    static func search(
        source: some DirectoryChildSource,
        startRecordNumber: UInt64,
        rootPath: String,
        pattern: String?,
        kind: EntryKind?,
        caseSensitive: Bool = false,
        maxDepth: Int,
        onMatch: (String) -> Void,
        onError: (String) -> Void = { _ in }
    ) async throws -> Result {
        var result = Result()
        let walker = DirectoryWalker(source: source)
        try await walker.walk(from: startRecordNumber, rootPath: rootPath, maxDepth: maxDepth) { event in
            switch event {
            case let .entry(node):
                switch kind {
                case .f where node.isDirectory: return
                case .d where !node.isDirectory: return
                default: break
                }
                if let pattern,
                   !Glob.matches(pattern: pattern, name: node.name, caseInsensitive: !caseSensitive) {
                    return
                }
                result.matches += 1
                onMatch(node.path)
            case let .failure(failure):
                result.errors += 1
                onError("\(failure.path): \(failure.reason)")
            }
        }
        return result
    }
}
