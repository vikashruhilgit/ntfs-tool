import XCTest
import NTFSCore
@testable import ntfsctl

/// Tests for the two walking subcommands.
///
/// Three layers:
///   1. Pure renderer / matcher tests — no volume, no I/O.
///   2. An end-to-end walk over a writable copy of `small.img` proving the
///      rendered depth bound and the trailing count summary agree with an
///      independent `enumerate`-based walk.
///   3. A structural test enforcing the load-bearing constraint of this
///      feature: neither subcommand may re-implement traversal.
final class TreeFindTests: XCTestCase {

    // MARK: - Fixture plumbing (mirrors MvIntegrationTests)

    private func repoRoot(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // ntfsctlTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ntfsctl
            .deletingLastPathComponent()  // Tools
            .deletingLastPathComponent()  // repo root
    }

    private func mutableFixtureCopy() throws -> String {
        let source = repoRoot()
            .appendingPathComponent("Packages/NTFSCore/Tests/NTFSCoreTests/Fixtures/small.img")
            .path
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

    // MARK: - 1. TreeRenderer (pure)

    /// Connectors and indentation for a small hand-built tree:
    ///
    ///     ├── a/
    ///     │   ├── a1
    ///     │   └── a2
    ///     └── b
    func testRendererDrawsConnectorsAndIndentation() {
        var renderer = TreeRenderer()
        var lines: [String] = []
        lines.append(renderer.line(name: "a",  isDirectory: true,  depth: 1, isLastSibling: false))
        lines.append(renderer.line(name: "a1", isDirectory: false, depth: 2, isLastSibling: false))
        lines.append(renderer.line(name: "a2", isDirectory: false, depth: 2, isLastSibling: true))
        lines.append(renderer.line(name: "b",  isDirectory: false, depth: 1, isLastSibling: true))

        XCTAssertEqual(lines, [
            "├── a/",
            "│   ├── a1",
            "│   └── a2",
            "└── b",
        ])
    }

    /// A last-child directory's descendants indent with spaces, not `│`.
    func testRendererUsesBlankGutterUnderALastChildDirectory() {
        var renderer = TreeRenderer()
        _ = renderer.line(name: "only", isDirectory: true, depth: 1, isLastSibling: true)
        let child = renderer.line(name: "deep", isDirectory: false, depth: 2, isLastSibling: true)
        XCTAssertEqual(child, "    └── deep")
    }

    func testRendererCountsAndPluralization() {
        var renderer = TreeRenderer()
        XCTAssertEqual(renderer.summary, "0 directories, 0 files")
        _ = renderer.line(name: "d", isDirectory: true, depth: 1, isLastSibling: false)
        _ = renderer.line(name: "f", isDirectory: false, depth: 1, isLastSibling: true)
        XCTAssertEqual(renderer.summary, "1 directory, 1 file")
        _ = renderer.line(name: "f2", isDirectory: false, depth: 1, isLastSibling: true)
        XCTAssertEqual(renderer.summary, "1 directory, 2 files")
    }

    // MARK: - 1b. GlobMatcher / type filter (pure)

    func testGlobMatcherHandlesWildcardsCaseInsensitively() {
        XCTAssertTrue(GlobMatcher(pattern: "*.jpg").matches("photo.jpg"))
        XCTAssertTrue(GlobMatcher(pattern: "*.jpg").matches("PHOTO.JPG"),
                      "NTFS name matching is case-insensitive; the glob must follow")
        XCTAssertTrue(GlobMatcher(pattern: "IMG_?.txt").matches("img_4.txt"))
        XCTAssertTrue(GlobMatcher(pattern: "*").matches("anything"))
        XCTAssertFalse(GlobMatcher(pattern: "*.jpg").matches("photo.png"))
        XCTAssertFalse(GlobMatcher(pattern: "IMG_?.txt").matches("img_44.txt"))
    }

    // MARK: - 2. End-to-end: depth bound + summary vs an independent walk

    /// `tree --depth 2`'s rendered lines and its trailing count summary must
    /// agree with an independent two-level `enumerate` walk of the same
    /// fixture — the acceptance criterion that the counts are real.
    func testTreeDepthTwoRenderingAndCountsMatchIndependentWalk() async throws {
        let path = try mutableFixtureCopy()

        // Seed a third level so a depth-2 bound is actually load-bearing.
        do {
            let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))
            let aa = try await volume.createFile(named: "aa", inDirectory: 5, isDirectory: true)
            let bb = try await volume.createFile(named: "bb", inDirectory: aa, isDirectory: true)
            _ = try await volume.createFile(named: "too-deep.txt", inDirectory: bb)
        }

        // Independent oracle — plain enumerate, no DirectoryWalker.
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        var expectedDirs = 0
        var expectedFiles = 0
        var expectedNames: [String] = []
        let level1 = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos && $0.name != "." }
        for entry in level1 {
            entry.isDirectory ? (expectedDirs += 1) : (expectedFiles += 1)
            expectedNames.append(entry.name)
            guard entry.isDirectory else { continue }
            let level2 = try await volume.enumerate(directory: entry.recordNumber)
                .filter { $0.fileName.namespace != .dos && $0.name != "." }
            for child in level2 {
                child.isDirectory ? (expectedDirs += 1) : (expectedFiles += 1)
                expectedNames.append(child.name)
            }
        }

        // Drive the real subcommand's walker + renderer.
        let walker = DirectoryWalker(volume: volume, root: 5, basePath: "/", maxDepth: 2)
        var renderer = TreeRenderer()
        var rendered: [String] = []
        var renderedNames: [String] = []
        while let event = await walker.next() {
            guard case .entry(let entry) = event else {
                return XCTFail("clean fixture should not produce walk errors")
            }
            XCTAssertLessThanOrEqual(entry.depth, 2, "--depth 2 must not render anything deeper")
            rendered.append(renderer.line(for: entry))
            renderedNames.append(entry.name)
        }

        XCTAssertEqual(renderedNames.sorted(), expectedNames.sorted())
        XCTAssertEqual(renderer.summary, "\(expectedDirs) directories, \(expectedFiles) files")
        XCTAssertFalse(rendered.contains { $0.hasSuffix("too-deep.txt") },
                       "the depth-3 entry must be excluded by --depth 2")
    }

    /// `find`'s matching semantics over a real walk: glob finds a deeply
    /// nested file at its full path, and `--type` filters correctly.
    func testFindMatchesDeepFileByGlobAndFiltersByType() async throws {
        let path = try mutableFixtureCopy()
        do {
            let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))
            let aa = try await volume.createFile(named: "aa", inDirectory: 5, isDirectory: true)
            let bb = try await volume.createFile(named: "bb", inDirectory: aa, isDirectory: true)
            _ = try await volume.createFile(named: "needle.dat", inDirectory: bb)
        }

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        let matcher = GlobMatcher(pattern: "NEEDLE.*")

        var matchedPaths: [String] = []
        var directoryPaths: [String] = []
        let walker = DirectoryWalker(volume: volume, root: 5, basePath: "/")
        while let event = await walker.next() {
            guard case .entry(let entry) = event else { continue }
            if matcher.matches(entry.name), EntryTypeFilter.f.admits(entry) {
                matchedPaths.append(entry.path)
            }
            if EntryTypeFilter.d.admits(entry) {
                directoryPaths.append(entry.path)
            }
        }

        XCTAssertEqual(matchedPaths, ["/aa/bb/needle.dat"],
                       "glob must find the nested file at its correct full path")
        XCTAssertTrue(directoryPaths.contains("/aa/bb"))
        XCTAssertFalse(directoryPaths.contains("/aa/bb/needle.dat"),
                       "--type d must exclude files")
    }

    // MARK: - 3. Structural: one shared walker, no duplicated traversal

    /// The load-bearing constraint. Both subcommands must consume the shared
    /// NTFSCore walker and neither may re-implement descent — enforced as a
    /// source-text check so it can't quietly regress.
    func testSubcommandsConsumeTheSharedWalkerAndDoNotReimplementTraversal() throws {
        let sources = repoRoot().appendingPathComponent("Tools/ntfsctl/Sources/ntfsctl")
        for file in ["Tree.swift", "Find.swift"] {
            let url = sources.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("could not read \(url.path)")
            }
            XCTAssertTrue(text.contains("DirectoryWalker("),
                          "\(file) must construct the shared walker")
            XCTAssertTrue(text.contains(".next()"),
                          "\(file) must drive the shared walker's cursor")
            XCTAssertFalse(text.contains("enumerate(directory:"),
                           "\(file) must not enumerate directories itself — traversal lives in NTFSCore's DirectoryWalker")
        }
    }

    /// Both subcommands must be reachable from the CLI's subcommand list.
    func testTreeAndFindAreRegisteredSubcommands() {
        let names = Ntfsctl.configuration.subcommands.map { $0._commandName }
        XCTAssertTrue(names.contains("tree"), "got \(names)")
        XCTAssertTrue(names.contains("find"), "got \(names)")
    }
}
