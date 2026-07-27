import ArgumentParser
import Foundation
import NTFSCore
#if canImport(Darwin)
import Darwin
#endif

/// `ntfsctl find` — locate entries by name across a subtree.
///
/// The second pure consumer of `NTFSCore.DirectoryWalker`: this file contains
/// matching and printing only, no descent logic. (`tree` is the other.)
struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Recursively find entries whose name matches a glob pattern.",
        discussion: """
            Prints the full path of every match, one per line. Read-only.

            The pattern is a shell glob (*, ?, [...]) matched against each
            entry's NAME, not its path — like `find -name`. Quote it so the
            shell doesn't expand it first:

                ntfsctl find /dev/disk10s1 '*.jpg'
                ntfsctl find /dev/disk10s1 'DCIM' --type d
                ntfsctl find /dev/disk10s1 '*.txt' --from /Backups --depth 2

            Matching is case-sensitive. Uses the shared NTFSCore directory
            walker, so it is cycle-safe and an unreadable subdirectory is
            reported on stderr while the search continues elsewhere.
            """
    )

    enum EntryType: String, ExpressibleByArgument, CaseIterable {
        case f  // regular files only
        case d  // directories only
    }

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Glob pattern matched against entry names (quote it, e.g. '*.jpg').")
    var pattern: String

    @Option(name: .long, help: "Directory to search under. Default: / (whole volume).")
    var from: String = "/"

    @Option(name: [.customShort("L"), .long], help: "Maximum depth to descend (1 = the start directory's own children). Default: unlimited.")
    var depth: Int?

    @Option(name: .long, help: "Restrict matches by type: f (files) or d (directories).")
    var type: EntryType?

    func validate() throws {
        if let depth, depth < 1 {
            throw ValidationError("--depth must be at least 1 (got \(depth))")
        }
    }

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        guard let start = try await volume.resolvePath(from) else {
            throw ValidationError("--from path not found in volume: \(from) (hint: run `ntfsctl list \(device)` to see the root)")
        }

        try await Find.search(
            source: volume,
            start: start,
            startPath: from,
            pattern: pattern,
            type: type,
            maxDepth: depth,
            emit: { print($0) },
            reportError: { FileHandle.standardError.write(Data("ntfsctl find: \($0)\n".utf8)) }
        )
    }

    /// Walk `start` and emit the path of every entry whose name matches
    /// `pattern` (and `type`, when given). Returns the match count.
    ///
    /// Separated from `run()` so tests exercise the real matching path with a
    /// collecting sink. Streams: paths are emitted as they are found, never
    /// collected into an array first.
    @discardableResult
    static func search<Source: DirectoryEnumerating>(
        source: Source,
        start: UInt64,
        startPath: String,
        pattern: String,
        type: EntryType?,
        maxDepth: Int?,
        emit: (String) -> Void,
        reportError: (String) -> Void = { _ in }
    ) async throws -> Int {
        var matched = 0
        let walker = DirectoryWalker(source: source)
        try await walker.walk(from: start, rootPath: startPath, maxDepth: maxDepth) { event in
            switch event {
            case .entry(let node):
                guard typeMatches(node, type), globMatches(pattern: pattern, name: node.name) else { return }
                matched += 1
                emit(node.path)
            case .failure(let failure):
                reportError("\(failure.path): \(failure.message)")
            }
        }
        return matched
    }

    static func typeMatches(_ node: DirectoryWalkNode, _ type: EntryType?) -> Bool {
        switch type {
        case nil: return true
        case .f:  return !node.isDirectory
        case .d:  return node.isDirectory
        }
    }

    /// Shell-glob match, delegated to POSIX `fnmatch` so `*`, `?` and `[...]`
    /// behave exactly as users expect from `find -name`.
    ///
    /// `FNM_PERIOD` is deliberately NOT set: NTFS has no leading-dot
    /// convention, so `*` should match `.hidden` too.
    static func globMatches(pattern: String, name: String) -> Bool {
        pattern.withCString { patternBytes in
            name.withCString { nameBytes in
                fnmatch(patternBytes, nameBytes, 0) == 0
            }
        }
    }
}
