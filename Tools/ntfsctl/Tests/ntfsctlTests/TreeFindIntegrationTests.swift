import XCTest
@testable import NTFSCore
@testable import ntfsctl

/// End-to-end tests for the two consumers of NTFSCore's shared directory
/// walker: `ntfsctl tree` (render) and `ntfsctl find` (match).
///
/// Both are driven through their real rendering/matching entry points
/// (`Tree.render` / `Find.search`) against a writable copy of `small.img`
/// seeded with a nested tree, with a collecting sink instead of stdout.
///
/// The counts and paths are cross-checked against an independent recursive
/// `enumerate` walk written here in the test — the same oracle
/// `ntfsctl list`-by-hand would give.
final class TreeFindIntegrationTests: XCTestCase {

    // MARK: - Fixture plumbing (mirrors MvIntegrationTests)

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

    /// Seed:
    ///     /docs/
    ///     /docs/2026/
    ///     /docs/2026/report.txt
    ///     /docs/2026/holiday.jpg
    ///     /docs/readme.txt
    ///     /top.jpg
    /// on top of the committed fixture's `/hello.txt`, `/medium.txt`, `/sub/`.
    private func seedNestedTree(imagePath: String) async throws {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        let docs = try await volume.createFile(named: "docs", inDirectory: 5, isDirectory: true)
        let year = try await volume.createFile(named: "2026", inDirectory: docs, isDirectory: true)
        _ = try await volume.createFile(named: "report.txt", inDirectory: year)
        _ = try await volume.createFile(named: "holiday.jpg", inDirectory: year)
        _ = try await volume.createFile(named: "readme.txt", inDirectory: docs)
        _ = try await volume.createFile(named: "top.jpg", inDirectory: 5)
        try await volume.endWriteSession()
    }

    private func openSeededVolume() async throws -> Volume {
        let path = try mutableFixtureCopy()
        try await seedNestedTree(imagePath: path)
        return try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
    }

    // MARK: - Independent oracle (what a by-hand `list` walk would report)

    private struct OracleCounts: Equatable {
        var directories = 0
        var files = 0
        var paths: [String] = []
    }

    /// Recursive `enumerate` walk written directly against `Volume` — the
    /// deliberately-duplicated reference the shared walker is checked against.
    private func oracle(
        _ volume: Volume,
        directory: UInt64 = 5,
        prefix: String = "",
        maxDepth: Int?,
        depth: Int = 1,
        visited: Set<UInt64> = [5]
    ) async throws -> OracleCounts {
        var out = OracleCounts()
        if let maxDepth, depth > maxDepth { return out }
        for entry in try await volume.enumerate(directory: directory) {
            if entry.fileName.namespace == .dos || entry.name == "." || entry.name == ".." { continue }
            let path = prefix + "/" + entry.name
            out.paths.append(path)
            if entry.isDirectory {
                out.directories += 1
                guard !visited.contains(entry.recordNumber) else { continue }
                let sub = try await oracle(
                    volume, directory: entry.recordNumber, prefix: path,
                    maxDepth: maxDepth, depth: depth + 1,
                    visited: visited.union([entry.recordNumber])
                )
                out.directories += sub.directories
                out.files += sub.files
                out.paths += sub.paths
            } else {
                out.files += 1
            }
        }
        return out
    }

    // MARK: - tree

    func testTreeRendersGutterGlyphsForANestedSubtree() async throws {
        let volume = try await openSeededVolume()
        let resolved = try await volume.resolvePath("/docs")
        let start = try XCTUnwrap(resolved)

        var lines: [String] = []
        let summary = try await Tree.render(
            source: volume, start: start, rootLabel: "/docs", maxDepth: nil
        ) { lines.append($0) }

        XCTAssertEqual(lines, [
            "/docs",
            "├── 2026/",
            "│   ├── holiday.jpg",
            "│   └── report.txt",
            "└── readme.txt",
            "",
            "1 directory, 3 files"
        ], "unexpected tree output:\n\(lines.joined(separator: "\n"))")
        XCTAssertEqual(summary, Tree.Summary(directories: 1, files: 3, unreadableDirectories: 0))
    }

    func testTreeCountsMatchAnIndependentListWalk() async throws {
        let volume = try await openSeededVolume()

        for limit in [nil, 1, 2, 3] as [Int?] {
            var lines: [String] = []
            let summary = try await Tree.render(
                source: volume, start: 5, rootLabel: "/", maxDepth: limit
            ) { lines.append($0) }
            let reference = try await oracle(volume, maxDepth: limit)

            XCTAssertEqual(summary.directories, reference.directories,
                           "directory count mismatch at --depth \(String(describing: limit))")
            XCTAssertEqual(summary.files, reference.files,
                           "file count mismatch at --depth \(String(describing: limit))")
            XCTAssertEqual(summary.unreadableDirectories, 0)
            // Every entry the oracle saw is rendered exactly once, and the
            // rendered lines are entries + root + blank + summary.
            XCTAssertEqual(lines.count, reference.paths.count + 3)
            XCTAssertEqual(lines.last, summary.line)
        }
    }

    func testTreeDepthStopsAtTheLimit() async throws {
        let volume = try await openSeededVolume()

        var deep: [String] = []
        try await Tree.render(source: volume, start: 5, rootLabel: "/", maxDepth: 2) { deep.append($0) }
        XCTAssertTrue(deep.contains("├── docs/"), deep.joined(separator: "\n"))
        XCTAssertTrue(deep.contains(where: { $0.hasSuffix("2026/") }), "depth 2 must include /docs/2026")
        XCTAssertFalse(deep.contains(where: { $0.contains("report.txt") }),
                       "depth 2 must NOT include /docs/2026/report.txt")

        var shallow: [String] = []
        let summary = try await Tree.render(source: volume, start: 5, rootLabel: "/", maxDepth: 1) { shallow.append($0) }
        XCTAssertFalse(shallow.contains(where: { $0.hasSuffix("2026/") }), "depth 1 must stop at /docs")
        XCTAssertEqual(summary.files + summary.directories, shallow.count - 3)
    }

    func testTreeReportsAnUnreadableSubdirectoryInPlaceAndKeepsGoing() async throws {
        // A stub source is the only way to make one directory unreadable
        // without corrupting the image; the walker's own tests cover the
        // on-disk variant.
        let broken = BrokenSource()
        var lines: [String] = []
        let summary = try await Tree.render(
            source: broken, start: 5, rootLabel: "/", maxDepth: nil
        ) { lines.append($0) }

        XCTAssertEqual(lines, [
            "/",
            "├── bad/",
            "│   └── [unreadable: corruptOnDisk(description: \"stub: bad directory\")]",
            "└── good.txt",
            "",
            "1 directory, 1 file"
        ], "unexpected tree output:\n\(lines.joined(separator: "\n"))")
        XCTAssertEqual(summary.unreadableDirectories, 1)
    }

    func testTreeMarksACycleInsteadOfLooping() async throws {
        let cyclic = CyclicSource()
        var lines: [String] = []
        try await Tree.render(source: cyclic, start: 5, rootLabel: "/", maxDepth: nil) { lines.append($0) }

        XCTAssertEqual(lines, [
            "/",
            "└── loop/",
            "    └── back/",
            "        └── loop/  [already visited, not followed]",
            "",
            "3 directories, 0 files"
        ], "unexpected tree output:\n\(lines.joined(separator: "\n"))")
    }

    // MARK: - find

    func testFindMatchesGlobAndPrintsFullPaths() async throws {
        let volume = try await openSeededVolume()

        var hits: [String] = []
        let count = try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "*.jpg", type: nil, maxDepth: nil
        ) { hits.append($0) }

        XCTAssertEqual(count, 2)
        XCTAssertEqual(hits.sorted(), ["/docs/2026/holiday.jpg", "/top.jpg"])
    }

    func testFindLocatesADeeplyNestedFileByExactName() async throws {
        let volume = try await openSeededVolume()

        var hits: [String] = []
        try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "report.txt", type: nil, maxDepth: nil
        ) { hits.append($0) }

        XCTAssertEqual(hits, ["/docs/2026/report.txt"],
                       "find must report the full path of the nested match")
    }

    func testFindTypeFiltersFilesAndDirectories() async throws {
        let volume = try await openSeededVolume()

        var dirs: [String] = []
        try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "2026", type: .d, maxDepth: nil
        ) { dirs.append($0) }
        XCTAssertEqual(dirs, ["/docs/2026"])

        var files: [String] = []
        try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "2026", type: .f, maxDepth: nil
        ) { files.append($0) }
        XCTAssertTrue(files.isEmpty, "--type f must not match a directory: \(files)")

        var onlyFiles: [String] = []
        try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "*", type: .f, maxDepth: 1
        ) { onlyFiles.append($0) }
        XCTAssertTrue(onlyFiles.contains("/top.jpg"))
        XCTAssertFalse(onlyFiles.contains("/docs"), "--type f must exclude directories")
        XCTAssertFalse(onlyFiles.contains("/sub"))
    }

    func testFindHonoursDepthAndStartDirectory() async throws {
        let volume = try await openSeededVolume()

        var shallow: [String] = []
        try await Find.search(
            source: volume, start: 5, startPath: "/",
            pattern: "*.txt", type: nil, maxDepth: 2
        ) { shallow.append($0) }
        XCTAssertTrue(shallow.contains("/docs/readme.txt"))
        XCTAssertFalse(shallow.contains("/docs/2026/report.txt"), "depth 2 excludes depth-3 matches")

        let resolvedDocs = try await volume.resolvePath("/docs")
        let docs = try XCTUnwrap(resolvedDocs)
        var scoped: [String] = []
        try await Find.search(
            source: volume, start: docs, startPath: "/docs",
            pattern: "*.txt", type: nil, maxDepth: nil
        ) { scoped.append($0) }
        XCTAssertEqual(scoped.sorted(), ["/docs/2026/report.txt", "/docs/readme.txt"],
                       "--from must scope the search and still print full paths")
    }

    func testFindGlobSemanticsMatchShellExpectations() {
        XCTAssertTrue(Find.globMatches(pattern: "*.jpg", name: "holiday.jpg"))
        XCTAssertTrue(Find.globMatches(pattern: "holi*", name: "holiday.jpg"))
        XCTAssertTrue(Find.globMatches(pattern: "holiday.???", name: "holiday.jpg"))
        XCTAssertTrue(Find.globMatches(pattern: "[hf]oliday.jpg", name: "holiday.jpg"))
        XCTAssertTrue(Find.globMatches(pattern: "*", name: ".hidden"),
                      "FNM_PERIOD must stay off — NTFS has no dotfile convention")
        XCTAssertFalse(Find.globMatches(pattern: "*.jpg", name: "holiday.jpeg"))
        XCTAssertFalse(Find.globMatches(pattern: "*.JPG", name: "holiday.jpg"),
                       "matching is case-sensitive, like find -name")
    }

    func testFindReportsUnreadableDirectoriesWithoutAbortingTheSearch() async throws {
        let broken = BrokenSource()
        var hits: [String] = []
        var errors: [String] = []
        try await Find.search(
            source: broken, start: 5, startPath: "/",
            pattern: "*", type: nil, maxDepth: nil,
            emit: { hits.append($0) },
            reportError: { errors.append($0) }
        )
        XCTAssertEqual(hits, ["/bad", "/good.txt"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(try XCTUnwrap(errors.first).hasPrefix("/bad: "), "\(errors)")
    }

    // MARK: - Wiring / structural constraints

    func testBothSubcommandsAreRegisteredAndAppearInHelp() throws {
        let names = Ntfsctl.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("tree"), "\(names)")
        XCTAssertTrue(names.contains("find"), "\(names)")

        let help = Ntfsctl.helpMessage()
        XCTAssertTrue(help.contains("tree"), help)
        XCTAssertTrue(help.contains("find"), help)
    }

    func testDepthFlagIsValidated() throws {
        XCTAssertThrowsError(try Tree.parse(["/dev/null", "/", "--depth", "0"]).validate())
        XCTAssertNoThrow(try Tree.parse(["/dev/null", "/", "--depth", "1"]).validate())
        XCTAssertThrowsError(try Find.parse(["/dev/null", "*", "--depth", "0"]).validate())
        XCTAssertNoThrow(try Find.parse(["/dev/null", "*", "--depth", "2"]).validate())
    }

    /// The load-bearing structural constraint of this feature: `tree` and
    /// `find` must both descend via the ONE shared walker. Guarded at the
    /// source level so a future "just call enumerate here" shortcut fails a
    /// test instead of quietly re-introducing a second traversal.
    func testNeitherSubcommandImplementsItsOwnTraversal() throws {
        let sources = Self.subcommandSourceDirectory()

        for name in ["Tree.swift", "Find.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("DirectoryWalker"), "\(name) must consume the shared walker")
            XCTAssertFalse(text.contains("enumerate(directory"),
                           "\(name) must not touch Volume.enumerate — traversal lives in NTFSCore's walker only")
            XCTAssertFalse(text.contains("func walk"),
                           "\(name) must not define its own walk")
        }
    }

    /// `Tools/ntfsctl/Sources/ntfsctl`, derived from this file's location.
    private static func subcommandSourceDirectory(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // .../Tests/ntfsctlTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // .../Tools/ntfsctl
            .appendingPathComponent("Sources/ntfsctl")
    }

    // MARK: - Stub sources

    /// `/bad/` (always unreadable) + `/good.txt`.
    private struct BrokenSource: DirectoryEnumerating {
        func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
            switch recordNumber {
            case 5:
                return [
                    stubEntry(name: "bad", recordNumber: 20, isDirectory: true),
                    stubEntry(name: "good.txt", recordNumber: 21, isDirectory: false)
                ]
            default:
                throw NTFSError.corruptOnDisk(description: "stub: bad directory")
            }
        }
    }

    /// `/loop/back/loop` — the third entry points back at record 20.
    private struct CyclicSource: DirectoryEnumerating {
        func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
            switch recordNumber {
            case 5:  return [stubEntry(name: "loop", recordNumber: 20, isDirectory: true)]
            case 20: return [stubEntry(name: "back", recordNumber: 21, isDirectory: true)]
            case 21: return [stubEntry(name: "loop", recordNumber: 20, isDirectory: true)]
            default: throw NTFSError.corruptOnDisk(description: "stub: no such directory")
            }
        }
    }
}

/// Minimal `DirectoryEntry` for the stub sources, with the NTFS-internal
/// `FILE_NAME_INDEX_PRESENT` (0x10000000) bit set for directories.
private func stubEntry(name: String, recordNumber: UInt64, isDirectory: Bool) -> DirectoryEntry {
    DirectoryEntry(
        fileReference: recordNumber | (1 << 48),
        recordNumber: recordNumber,
        sequenceNumber: 1,
        fileName: FileName(
            parentDirectoryReference: 5,
            parentRecordNumber: 5,
            parentSequenceNumber: 1,
            creationTime: nil,
            modificationTime: nil,
            mftChangeTime: nil,
            accessTime: nil,
            allocatedSize: 0,
            realSize: 0,
            fileAttributes: isDirectory ? 0x1000_0000 : 0,
            namespace: .win32,
            name: name
        )
    )
}
