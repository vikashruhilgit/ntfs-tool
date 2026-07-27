import XCTest
import ArgumentParser
import NTFSCore
@testable import ntfsctl

/// CLI-level coverage for `ntfsctl tree` and `ntfsctl find` (AC3, AC3b, AC8,
/// AC9).
///
/// Both subcommands expose a `static emit(… into sink:)` seam precisely so
/// these tests can drive the REAL rendering/search code with an
/// array-appending sink instead of capturing stdout — the rest of
/// `ntfsctlTests` runs command structs in-process and has no stdout capture.
///
/// The AC9 count assertions are checked against an **independent** oracle: a
/// breadth-first `volume.enumerate` walk written here from scratch. It shares
/// no code with `DirectoryWalker`/`Tree` (different traversal order, different
/// data structures), so an off-by-one in either one fails the comparison
/// instead of cancelling out.
final class TreeFindTests: XCTestCase {

    // MARK: - Fixture plumbing (reimplemented locally; can't import test helper)

    /// Path to the committed read-only `small.img` fixture. The repo root is 5
    /// directories up from this file
    /// (Tools/ntfsctl/Tests/ntfsctlTests/ThisFile.swift), then
    /// Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img.
    private func fixturePath(_ file: String = #filePath) -> String {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // ntfsctlTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ntfsctl
            .deletingLastPathComponent()  // Tools
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img")
            .path
    }

    /// Copy the read-only fixture into a writable tmp file and register
    /// teardown to delete it. Skips the test if the fixture is missing.
    ///
    /// Every test here is read-only, but the fixture is still copied rather
    /// than opened in place: an accidental write must never reach the
    /// committed image.
    private func mutableFixtureCopy() throws -> String {
        let source = fixturePath()
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing at \(source); run scripts/make_test_images.sh")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsctl-treefind-\(UUID().uuidString)-small.img")
        try FileManager.default.copyItem(atPath: source, toPath: copy.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy.path
    }

    /// Open a read-only volume on `imagePath`.
    private func openVolume(_ imagePath: String) async throws -> Volume {
        let device = try FileHandleBlockDevice(openingFileAt: imagePath)
        return try await Volume(device: device)
    }

    // MARK: - Deep fixture (AC3)

    /// `small.img` is only two levels deep, so AC3's "at least 4 levels deep"
    /// case gets a fresh formatted image laid out as:
    ///
    /// ```
    /// /deep/a/pickdir/            (directory, 2 levels below /deep)
    /// /deep/a/b/note.txt
    /// /deep/a/b/c/pickme.jpg      (file,      4 levels below /deep)
    /// ```
    ///
    /// `pick*` deliberately matches one directory and one file at different
    /// depths, so `--type` and `--depth` each have something to exclude.
    private func makeDeepImage() async throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ntfsctl-treefind-deep-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw XCTSkip("cannot create temp image at \(path)")
        }
        // 32 MiB: `formatNTFS` needs ~4,457 clusters for its system files, so a
        // 16 MiB image (4,096 clusters at the 4 KiB default) is rejected.
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        // lockExclusive:false throughout: the actor-held FileHandle's deinit is
        // not deterministic, so an exclusive lock here can race the next open
        // in the same test. releaseAdvisoryLock() is called anyway for the
        // devices that take one.
        let formatDevice = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let size = try await formatDevice.size()
        try await Volume.formatNTFS(
            device: formatDevice,
            deviceSizeBytes: size,
            label: "TREEFIND",
            volumeSerial: 0x0BAD_F00D_0BAD_F00D
        )
        await formatDevice.releaseAdvisoryLock()

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        let deepRN = try await volume.createFile(named: "deep", inDirectory: 5, isDirectory: true)
        let aRN = try await volume.createFile(named: "a", inDirectory: deepRN, isDirectory: true)
        _ = try await volume.createFile(named: "pickdir", inDirectory: aRN, isDirectory: true)
        let bRN = try await volume.createFile(named: "b", inDirectory: aRN, isDirectory: true)
        _ = try await volume.createFile(named: "note.txt", inDirectory: bRN, isDirectory: false)
        let cRN = try await volume.createFile(named: "c", inDirectory: bRN, isDirectory: true)
        _ = try await volume.createFile(named: "pickme.jpg", inDirectory: cRN, isDirectory: false)
        try await volume.endWriteSession()
        await device.releaseAdvisoryLock()

        return path
    }

    // MARK: - Independent oracle (AC9)

    /// Breadth-first `enumerate` walk, counting exactly what `tree`'s summary
    /// claims to count.
    ///
    /// Deliberately NOT a re-render of `Tree`/`DirectoryWalker`: different
    /// traversal order (BFS vs. the walker's depth-first pre-order), separate
    /// code, written straight against `Volume.enumerate`. It encodes the same
    /// three contract rules and nothing else:
    ///
    /// 1. DOS 8.3 aliases are dropped (everything else — metafiles, the root's
    ///    `.` self-entry — is counted, mirroring `ntfsctl list`).
    /// 2. The walk root itself is not counted.
    /// 3. A directory record already descended into is still counted as an
    ///    entry but never descended into twice (the cycle rule; on `small.img`
    ///    this is what keeps the root's `.` self-entry from recursing).
    private func oracleCounts(
        volume: Volume,
        root: UInt64,
        maxDepth: Int
    ) async throws -> (directories: Int, files: Int) {
        var directories = 0
        var files = 0
        var descended: Set<UInt64> = [root]
        var frontier: [UInt64] = [root]
        var depth = 1

        while depth <= maxDepth, !frontier.isEmpty {
            var nextFrontier: [UInt64] = []
            for directory in frontier {
                let entries = try await volume.enumerate(directory: directory)
                for entry in entries where entry.fileName.namespace != .dos {
                    if entry.isDirectory {
                        directories += 1
                        if descended.insert(entry.recordNumber).inserted {
                            nextFrontier.append(entry.recordNumber)
                        }
                    } else {
                        files += 1
                    }
                }
            }
            frontier = nextFrontier
            depth += 1
        }
        return (directories, files)
    }

    // MARK: - Rendering helpers

    /// Depth of a rendered branch line, derived from its glyph prefix, or `nil`
    /// if the line is not a branch line.
    ///
    /// The prefix is a run of 4-wide ancestor columns (`│   ` for a live
    /// vertical, four spaces for a closed one) followed by the entry's own
    /// glyph. A line with `n` ancestor columns is at depth `n + 1`, so this
    /// doubles as the assertion that the glyph vocabulary is exactly the
    /// `/usr/bin/tree` set.
    private func renderedDepth(of line: String) -> Int? {
        var rest = Substring(line)
        var columns = 0
        while rest.hasPrefix("│   ") || rest.hasPrefix("    ") {
            rest = rest.dropFirst(4)
            columns += 1
        }
        guard rest.hasPrefix("├── ") || rest.hasPrefix("└── ") else { return nil }
        return columns + 1
    }

    // MARK: - AC8: subcommand registration

    /// AC8, asserted structurally against the parser configuration rather than
    /// by shelling out to a built binary and scraping `--help` (slow, and
    /// brittle across ArgumentParser versions).
    func testTreeAndFindAreRegisteredSubcommands() throws {
        let names = Ntfsctl.configuration.subcommands.map { String(describing: $0) }
        XCTAssertTrue(names.contains("Tree"), "Tree must be registered in Ntfsctl.subcommands; got \(names)")
        XCTAssertTrue(names.contains("Find"), "Find must be registered in Ntfsctl.subcommands; got \(names)")

        // The registered command names are what a user actually types.
        XCTAssertEqual(Tree.configuration.commandName, "tree")
        XCTAssertEqual(Find.configuration.commandName, "find")

        // Both are mentioned in the top-level discussion, so `ntfsctl --help`
        // surfaces them beyond the bare subcommand list.
        let discussion = Ntfsctl.configuration.discussion
        XCTAssertTrue(discussion.contains("tree"), "top-level discussion should mention `tree`")
        XCTAssertTrue(discussion.contains("find"), "top-level discussion should mention `find`")
    }

    // MARK: - AC9: tree rendering + summary

    /// AC9's headline assertion: the `N directories, M files` summary of
    /// `tree / --depth 2` on `small.img` equals the counts of an independent
    /// two-level `enumerate` walk of the same fixture.
    func testTreeSummaryMatchesIndependentTwoLevelEnumerateWalk() async throws {
        let imagePath = try mutableFixtureCopy()
        let volume = try await openVolume(imagePath)

        var lines: [String] = []
        try await Tree.emit(volume: volume, root: 5, rootLabel: "/", maxDepth: 2, into: { lines.append($0) })

        let oracle = try await oracleCounts(volume: volume, root: 5, maxDepth: 2)

        XCTAssertEqual(
            lines.last,
            "\(oracle.directories) directories, \(oracle.files) files",
            "tree's summary must match an independent two-level enumerate walk; render was:\n\(lines.joined(separator: "\n"))"
        )
        // A blank line separates the listing from the summary.
        XCTAssertEqual(lines.dropLast().last, "", "a blank line must precede the summary")

        // Guard against the oracle and the renderer agreeing on nothing: the
        // fixture's committed contents are known, so pin the counts too.
        // `tree` mirrors a raw $I30 listing, so the root walk includes the NTFS
        // metafiles ($MFT, $Extend, …) and the root's `.` self-entry, exactly
        // as `ntfsctl list` shows them.
        XCTAssertEqual(oracle.directories, 3, "small.img root+1 level holds $Extend/, ./ and sub/")
        XCTAssertEqual(oracle.files, 16, "small.img root+1 level holds 13 metafiles + hello.txt + medium.txt + sub/nested.txt")

        // The summary counts entries, not rendered lines, but on a clean walk
        // (no [error: …] lines) they must agree.
        let branchLines = lines.filter { renderedDepth(of: $0) != nil }
        XCTAssertEqual(
            branchLines.count, oracle.directories + oracle.files,
            "every counted entry should have produced exactly one branch line"
        )
    }

    /// AC9's rendering half: `/usr/bin/tree` glyph vocabulary, a hard depth
    /// bound on the rendered lines, and a trailing `/` on directories.
    func testTreeRendersGnuStyleGlyphsAndRespectsDepthBound() async throws {
        let imagePath = try mutableFixtureCopy()
        let volume = try await openVolume(imagePath)

        var lines: [String] = []
        try await Tree.emit(volume: volume, root: 5, rootLabel: "/", maxDepth: 2, into: { lines.append($0) })

        XCTAssertEqual(lines.first, "/", "the root label is the header line")

        // Body = everything between the header and the trailing blank+summary.
        let body = Array(lines.dropFirst().dropLast(2))
        XCTAssertFalse(body.isEmpty)

        for line in body {
            guard let depth = renderedDepth(of: line) else {
                return XCTFail("line is not a `/usr/bin/tree`-style branch line: \(line.debugDescription)")
            }
            XCTAssertLessThanOrEqual(depth, 2, "--depth 2 must not render a level-3 line: \(line.debugDescription)")
        }

        // Both sibling glyphs and the live-vertical continuation are exercised
        // by this fixture ($Extend/ has children and is not the last sibling).
        XCTAssertTrue(body.contains { $0.hasPrefix("├── ") }, "non-last siblings use ├── ")
        XCTAssertTrue(body.contains { $0.hasPrefix("└── ") }, "the last sibling uses └── ")
        XCTAssertTrue(body.contains { $0.hasPrefix("│   ") }, "a non-last ancestor keeps its vertical bar")
        XCTAssertTrue(body.contains { $0.hasPrefix("    ") }, "a last ancestor's column is blanked")

        // Directories are marked with a trailing slash; files are not.
        XCTAssertTrue(body.contains("├── sub/") || body.contains("└── sub/"),
                      "directories render with a trailing /; got:\n\(body.joined(separator: "\n"))")
        XCTAssertTrue(body.contains { $0.hasSuffix("hello.txt") },
                      "files render without a trailing /; got:\n\(body.joined(separator: "\n"))")

        // nested.txt is the level-2 entry; nothing below it exists at level 3.
        XCTAssertTrue(body.contains { $0.hasSuffix("nested.txt") && renderedDepth(of: $0) == 2 },
                      "/sub/nested.txt is the depth-2 entry")
    }

    /// The summary line always uses the plural nouns, even at a count of one.
    /// This is deliberate literal fidelity to AC9's `N directories, M files`
    /// wording — `/usr/bin/tree` singularizes, we do not. Pinned so a later
    /// "fix" cannot silently change the contract.
    func testTreeSummaryAlwaysUsesPluralNouns() async throws {
        let imagePath = try await makeDeepImage()
        let volume = try await openVolume(imagePath)

        guard let bRN = try await volume.resolvePath("/deep/a/b") else {
            return XCTFail("deep fixture should contain /deep/a/b")
        }

        var lines: [String] = []
        try await Tree.emit(volume: volume, root: bRN, rootLabel: "/deep/a/b", maxDepth: 1, into: { lines.append($0) })

        let oracle = try await oracleCounts(volume: volume, root: bRN, maxDepth: 1)
        XCTAssertEqual(oracle.directories, 1, "/deep/a/b holds exactly one directory (c/)")
        XCTAssertEqual(oracle.files, 1, "/deep/a/b holds exactly one file (note.txt)")
        XCTAssertEqual(lines.last, "1 directories, 1 files",
                       "the summary is always plural; render was:\n\(lines.joined(separator: "\n"))")
    }

    // MARK: - AC3b: bare target is a path, --recnum is opt-in

    /// A bare numeric argument must be resolved as a PATH, not auto-parsed as
    /// an MFT record number — the post-v0.2.0 CLI contract. `small.img` has no
    /// entry named `5`, so the real command must fail with the resolver's
    /// `path not found in volume` ValidationError rather than quietly walking
    /// record 5 (the volume root).
    func testBareNumericTargetIsResolvedAsPathNotRecordNumber() async throws {
        let imagePath = try mutableFixtureCopy()

        for makeCommand in [
            { try Tree.parse([imagePath, "5"]) as any AsyncParsableCommand },
            { try Find.parse([imagePath, "5", "--name", "*"]) as any AsyncParsableCommand }
        ] {
            var command = try makeCommand()
            do {
                try await command.run()
                XCTFail("a bare `5` must NOT be auto-parsed as MFT record 5")
            } catch let error as ValidationError {
                XCTAssertTrue(
                    error.message.contains("path not found in volume: 5"),
                    "expected the path-resolution failure, got: \(error.message)"
                )
            }
        }
    }

    /// The `--recnum` opt-in still reaches record 5, and record 5 really is the
    /// volume root (asserted through the fixture's known contents, not by
    /// trusting the number).
    func testRecnumFlagResolvesTargetAsRecordNumber() async throws {
        let imagePath = try mutableFixtureCopy()
        let volume = try await openVolume(imagePath)

        // Parse through the real command structs so the flag plumbing — not
        // just TargetResolver — is what's under test.
        let treeCommand = try Tree.parse([imagePath, "5", "--recnum"])
        XCTAssertTrue(treeCommand.recnum)
        let findCommand = try Find.parse([imagePath, "5", "--recnum", "--name", "*.txt"])
        XCTAssertTrue(findCommand.recnum)

        for target in [treeCommand.target, findCommand.target] {
            let resolved = try await TargetResolver.resolve(target, recnumFlag: true, volume: volume)
            XCTAssertEqual(resolved, 5)
        }

        // Record 5 is the root: it holds the fixture's top-level entries.
        let names = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos }
            .map(\.name)
        XCTAssertTrue(names.contains("hello.txt"), "record 5 should be the volume root; got \(names)")
        XCTAssertTrue(names.contains("sub"), "record 5 should be the volume root; got \(names)")
    }

    // MARK: - AC3: find over a deeply nested tree

    /// The printed line for a match 4 levels below the search root is that
    /// file's correct full path.
    func testFindPrintsFullPathOfDeeplyNestedMatch() async throws {
        let imagePath = try await makeDeepImage()
        let volume = try await openVolume(imagePath)
        guard let deepRN = try await volume.resolvePath("/deep") else {
            return XCTFail("deep fixture should contain /deep")
        }

        var matches: [String] = []
        var errors: [String] = []
        try await Find.emit(
            volume: volume,
            root: deepRN,
            rootPath: "/deep",
            namePattern: "*.jpg",
            type: nil,
            maxDepth: .max,
            into: { matches.append($0) },
            errors: { errors.append($0) }
        )

        XCTAssertEqual(matches, ["/deep/a/b/c/pickme.jpg"],
                       "the glob must print the match's full path from the search root")
        XCTAssertEqual(errors, [], "a healthy fixture must produce no walk errors")
    }

    /// `--type f` emits no directory paths, `--type d` emits no file paths, and
    /// `--depth N` emits nothing more than N components below the search root.
    func testFindTypeAndDepthFilters() async throws {
        let imagePath = try await makeDeepImage()
        let volume = try await openVolume(imagePath)
        guard let deepRN = try await volume.resolvePath("/deep") else {
            return XCTFail("deep fixture should contain /deep")
        }

        func find(type: FindType?, maxDepth: Int) async throws -> [String] {
            var matches: [String] = []
            try await Find.emit(
                volume: volume,
                root: deepRN,
                rootPath: "/deep",
                namePattern: "pick*",
                type: type,
                maxDepth: maxDepth,
                into: { matches.append($0) },
                errors: { XCTFail("unexpected walk error: \($0)") }
            )
            return matches.sorted()
        }

        // Unfiltered: one directory (depth 2) and one file (depth 4).
        let all = try await find(type: nil, maxDepth: .max)
        XCTAssertEqual(all, ["/deep/a/b/c/pickme.jpg", "/deep/a/pickdir"])

        // --type f drops the directory.
        let filesOnly = try await find(type: .f, maxDepth: .max)
        XCTAssertEqual(filesOnly, ["/deep/a/b/c/pickme.jpg"], "--type f must emit no directory paths")

        // --type d drops the file.
        let dirsOnly = try await find(type: .d, maxDepth: .max)
        XCTAssertEqual(dirsOnly, ["/deep/a/pickdir"], "--type d must emit no file paths")

        // --depth 2 keeps only what is at most 2 components below /deep.
        let shallow = try await find(type: nil, maxDepth: 2)
        XCTAssertEqual(shallow, ["/deep/a/pickdir"], "--depth 2 must exclude the depth-4 match")
        for path in shallow {
            let extraComponents = path
                .dropFirst("/deep".count)
                .split(separator: "/")
                .count
            XCTAssertLessThanOrEqual(extraComponents, 2, "no path may sit more than 2 components below the search root")
        }

        // The glob is case-insensitive (`find -name` on NTFS semantics).
        var upper: [String] = []
        try await Find.emit(
            volume: volume,
            root: deepRN,
            rootPath: "/deep",
            namePattern: "PICKME.*",
            type: nil,
            maxDepth: .max,
            into: { upper.append($0) },
            errors: { XCTFail("unexpected walk error: \($0)") }
        )
        XCTAssertEqual(upper, ["/deep/a/b/c/pickme.jpg"], "matching must be case-insensitive")
    }

    /// A target that resolves but is not a directory is reported through the
    /// error sink and does NOT throw — `find`/`tree` exit 0 in that case, while
    /// an unresolvable target fails in `TargetResolver` with exit 64. Pinned
    /// because it is the deliberate split documented on `Find.emit`.
    func testFindOnNonDirectoryTargetReportsErrorWithoutThrowing() async throws {
        let imagePath = try mutableFixtureCopy()
        let volume = try await openVolume(imagePath)
        guard let fileRN = try await volume.resolvePath("/hello.txt") else {
            throw XCTSkip("fixture should contain /hello.txt")
        }

        var matches: [String] = []
        var errors: [String] = []
        try await Find.emit(
            volume: volume,
            root: fileRN,
            rootPath: "/hello.txt",
            namePattern: "*",
            type: nil,
            maxDepth: .max,
            into: { matches.append($0) },
            errors: { errors.append($0) }
        )

        XCTAssertEqual(matches, [], "a non-directory target yields no matches")
        XCTAssertEqual(errors.count, 1, "exactly one contained error, got: \(errors)")
        XCTAssertTrue(errors[0].hasPrefix("find: /hello.txt: "), "error names the offending path; got: \(errors[0])")
    }
}
