import ArgumentParser
import Darwin
import Foundation
import NTFSCore

/// `--type` filter for ``Find``: `f` restricts matches to non-directories,
/// `d` to directories. Omitting the option matches both.
enum FindType: String, ExpressibleByArgument, CaseIterable {
    case f
    case d
}

/// Recursive name search over an NTFS directory tree, `find -name` style.
///
/// Contains **no traversal logic of its own** — every descent, depth bound,
/// cycle guard and DOS-alias filter lives in `NTFSCore.DirectoryWalker`. This
/// file only filters the walker's event stream and prints paths.
struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Recursively find entries whose name matches a glob pattern.",
        discussion: """
            Prints one full path per match, `/`-joined from the search root.

            The glob is matched against each entry's NAME, not its full path —
            the same rule as `/usr/bin/find -name`, so `--name '*.jpg'` matches
            a `.jpg` at any depth. Matching is case-insensitive, which is the
            right default for NTFS (Windows treats file names case-insensitively
            and $I30 is collated that way).

            Like `list` and `tree`, the search is a faithful view of what is in
            each directory's $I30 index: searching from the volume root
            therefore also sees the NTFS metafiles ($MFT, $MFTMirr, $Extend, …)
            and the root's `.` self-entry. Only DOS 8.3 aliases are collapsed.

            A directory that cannot be read (bad sector, corrupt $INDEX_ROOT)
            is reported on stderr and does not abort the search; matches found
            elsewhere are still printed.

            The bare target argument is a PATH. Pass --recnum for the
            MFT-record-number form.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "Directory to search under: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String = "/"

    @Option(name: .long, help: "Glob matched case-insensitively against each entry's name, e.g. '*.jpg'.")
    var name: String

    @Option(name: .long, help: "Maximum number of levels to descend (default: unlimited).")
    var depth: Int?

    @Option(name: .long, help: "Restrict matches to files (f) or directories (d). Default: both.")
    var type: FindType?

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
            // With --recnum the argument is a record number, NOT a path, so it
            // must not become the printed path prefix — that would emit
            // `5/foo.txt`, which is neither a path nor a record number. There
            // is no reverse record-number → path lookup in NTFSCore, so paths
            // are rendered relative to the search root with a leading `/`.
            // They are genuinely absolute only when the record is the volume
            // root (5), which is the overwhelmingly common --recnum case.
            rootPath: recnum ? "" : target,
            namePattern: name,
            type: type,
            maxDepth: depth ?? .max,
            into: { print($0) }
        )
    }

    // MARK: - Search

    /// Walk the tree rooted at `root` and hand every matching entry's full path
    /// to `sink`.
    ///
    /// Paths are streamed one at a time and never accumulated into an array —
    /// that would re-buffer at the CLI layer exactly what ``DirectoryWalker``
    /// is careful not to buffer. Tests drive this directly with an
    /// array-appending sink instead of capturing stdout.
    ///
    /// ## Matching
    ///
    /// `namePattern` is applied to the entry's own name via `fnmatch(3)` with
    /// `FNM_CASEFOLD`, matching `find -name` semantics rather than `-path`
    /// semantics. `type` narrows to directories or non-directories; `nil`
    /// matches both.
    ///
    /// ## What is searched
    ///
    /// Exactly the entries the walker emits: the whole subtree under `root`,
    /// bounded by `maxDepth`, minus DOS 8.3 aliases. The search root itself is
    /// never a candidate (the walker emits children, not the start node), which
    /// differs from `/usr/bin/find` — it keeps output identical whether the
    /// root was named by path or by `--recnum`, where its name is unknown.
    ///
    /// ## Errors
    ///
    /// A ``WalkError`` — including the "search root could not be read" case,
    /// which is what a non-directory target produces — goes to `errorSink` and
    /// the search continues.
    ///
    /// **Deliberate behavioral choice, flagged for the docs pass:** a target
    /// that resolves but cannot be walked (e.g. `find <img> /some/file.txt`)
    /// reports on stderr and exits 0, whereas a target that does not resolve at
    /// all fails in `TargetResolver` with a `ValidationError` (exit 64). The
    /// split is intentional: exit 64 means "the command line was wrong", and a
    /// path that resolved fine is not a usage error. This matches `tree`'s
    /// inline-error behavior, and consistency between the two new subcommands
    /// was judged more valuable than matching `find(1)`'s nonzero exit for an
    /// inaccessible start point.
    ///
    /// - Parameters:
    ///   - volume: Volume to read from.
    ///   - root: MFT record number of the directory to search under.
    ///   - rootPath: Path prefix that emitted paths are joined onto. Pass the
    ///     empty string when the root's path is unknown.
    ///   - namePattern: Glob matched against each entry's name.
    ///   - type: Optional file/directory narrowing.
    ///   - maxDepth: Deepest level to descend. Children of the root are level 1.
    ///   - sink: Receives each matching full path, without a trailing newline.
    ///   - errorSink: Receives each unreadable-directory message, without a
    ///     trailing newline. Defaults to stderr.
    static func emit(
        volume: NTFSCore.Volume,
        root: UInt64,
        rootPath: String,
        namePattern: String,
        type: FindType?,
        maxDepth: Int,
        into sink: (String) -> Void,
        errors errorSink: (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) async throws {
        var walker = DirectoryWalker(
            volume: volume,
            root: root,
            rootPath: rootPath,
            maxDepth: maxDepth
        )

        while let event = await walker.next() {
            switch event {
            case .entry(let entry):
                guard matchesType(entry.isDirectory, type) else { continue }
                guard globMatches(namePattern, entry.name) else { continue }
                // `entry.path` is already `/`-joined by the walker; re-deriving
                // it here would be a second, divergent implementation.
                sink(entry.path)

            case .error(let error):
                // A start-directory failure carries the caller's root label
                // verbatim, which may be empty — print something addressable.
                let where_ = error.path.isEmpty ? "recnum \(error.recordNumber)" : error.path
                // NTFSError has no CustomStringConvertible, so this prints the
                // raw enum case. That is still the most informative rendering
                // available: `localizedDescription` on a plain Swift error enum
                // degrades to "The operation couldn't be completed."
                errorSink("find: \(where_): \(error.underlying)")
            }
        }
    }

    /// `nil` matches both kinds; `.d` keeps directories, `.f` keeps everything
    /// else.
    private static func matchesType(_ isDirectory: Bool, _ type: FindType?) -> Bool {
        switch type {
        case .none: return true
        case .d: return isDirectory
        case .f: return !isDirectory
        }
    }

    /// Case-insensitive shell glob, via libc so the pattern language is exactly
    /// the one users already know from `find -name` (`*`, `?`, `[...]`).
    private static func globMatches(_ pattern: String, _ name: String) -> Bool {
        pattern.withCString { p in
            name.withCString { n in
                fnmatch(p, n, FNM_CASEFOLD) == 0
            }
        }
    }
}
