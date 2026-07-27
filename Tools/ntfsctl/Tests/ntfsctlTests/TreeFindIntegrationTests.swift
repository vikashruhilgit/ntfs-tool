import XCTest
import NTFSCore
@testable import ntfsctl

/// End-to-end tests for `ntfsctl tree` and `ntfsctl find` through the REAL CLI
/// rendering/matching code, against a writable copy of the `small.img`
/// fixture seeded with a known nested tree.
///
/// Both subcommands are thin consumers of the ONE shared
/// `NTFSCore.DirectoryWalker` — these tests cover the consumer halves
/// (rendering, counting, glob/type filtering, argument wiring); the walker's
/// own guarantees (cycle safety, depth bound, error containment, streaming)
/// are covered by `DirectoryWalkerTests` in NTFSCore.
final class TreeFindIntegrationTests: XCTestCase {

    // MARK: - Fixture plumbing

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
    ///   /walk/
    ///     ├── a/
    ///     │   ├── b/
    ///     │   │   └── deep.txt
    ///     │   └── IMG_0001.jpg
    ///     ├── empty/
    ///     └── top.txt
    private func seedTree(imagePath: String) async throws {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        try await volume.beginWriteSession()
        let walk = try await volume.createFile(named: "walk", inDirectory: 5, isDirectory: true)
        let a = try await volume.createFile(named: "a", inDirectory: walk, isDirectory: true)
        let b = try await volume.createFile(named: "b", inDirectory: a, isDirectory: true)
        _ = try await volume.createFile(named: "empty", inDirectory: walk, isDirectory: true)
        let deep = try await volume.createFile(named: "deep.txt", inDirectory: b, isDirectory: false)
        try await volume.write(at: deep, offset: 0, bytes: Data("deep\n".utf8))
        _ = try await volume.createFile(named: "IMG_0001.jpg", inDirectory: a, isDirectory: false)
        _ = try await volume.createFile(named: "top.txt", inDirectory: walk, isDirectory: false)
        try await volume.endWriteSession()
    }

    private func openVolume(_ imagePath: String) async throws -> Volume {
        try await Volume(device: try FileHandleBlockDevice(openingFileAt: imagePath))
    }

    private func recnum(_ volume: Volume, _ path: String) async throws -> UInt64 {
        guard let rn = try await volume.resolvePath(path) else {
            throw XCTSkip("seeded path missing: \(path)")
        }
        return rn
    }

    /// Independent oracle: count entries under a directory with plain
    /// `enumerate` recursion, exactly like running `ntfsctl list` at every
    /// level by hand.
    private func referenceCounts(
        volume: Volume,
        from start: UInt64,
        maxDepth: Int
    ) async throws -> (directories: Int, files: Int) {
        var directories = 0
        var files = 0
        var visited: Set<UInt64> = [start]

        func descend(_ rn: UInt64, _ depth: Int) async throws {
            guard depth <= maxDepth else { return }
            for child in try await volume.enumerate(directory: rn)
                where child.fileName.namespace != .dos {
                if child.isDirectory {
                    directories += 1
                    if visited.insert(child.recordNumber).inserted {
                        try await descend(child.recordNumber, depth + 1)
                    }
                } else {
                    files += 1
                }
            }
        }
        try await descend(start, 1)
        return (directories, files)
    }

    // MARK: - tree

    func testTreeRendersNestedStructureWithConnectorsAndSummary() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let walkRN = try await recnum(volume, "/walk")

        var lines: [String] = []
        let summary = try await Tree.render(
            source: volume,
            startRecordNumber: walkRN,
            rootPath: "/walk",
            maxDepth: Int.max
        ) { lines.append($0) }

        // Sibling order is $I30 collation order (uppercased UTF-16 code
        // units), which sorts "b" before "IMG_0001.jpg" — the walker yields
        // on-disk order and does not re-sort.
        XCTAssertEqual(lines, [
            "/walk",
            "├── a/",
            "│   ├── b/",
            "│   │   └── deep.txt",
            "│   └── IMG_0001.jpg",
            "├── empty/",
            "└── top.txt",
            "",
            "3 directories, 3 files"
        ], "rendered tree:\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(summary, Tree.Summary(directories: 3, files: 3, errors: 0))
    }

    /// `--depth N` stops at depth N, and the counts match an independent
    /// `enumerate`-based walk of the same fixture at the same bound.
    func testTreeDepthBoundStopsAndCountsMatchIndependentWalk() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let walkRN = try await recnum(volume, "/walk")

        for depth in [1, 2, 3, Int.max] {
            var lines: [String] = []
            let summary = try await Tree.render(
                source: volume,
                startRecordNumber: walkRN,
                rootPath: "/walk",
                maxDepth: depth
            ) { lines.append($0) }

            let reference = try await referenceCounts(volume: volume, from: walkRN, maxDepth: depth)
            XCTAssertEqual(summary.directories, reference.directories, "directory count at depth \(depth)")
            XCTAssertEqual(summary.files, reference.files, "file count at depth \(depth)")
            XCTAssertEqual(summary.errors, 0)
            XCTAssertFalse(lines.contains { $0.contains("deep.txt") } && depth < 3,
                           "depth \(depth) must not reach /walk/a/b/deep.txt")
        }

        // Depth 1 shows only the immediate children, with the directories that
        // were not descended marked.
        var depthOne: [String] = []
        _ = try await Tree.render(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk", maxDepth: 1
        ) { depthOne.append($0) }
        XCTAssertEqual(depthOne, [
            "/walk",
            "├── a/  [depth limit]",
            "├── empty/  [depth limit]",
            "└── top.txt",
            "",
            "2 directories, 1 file"
        ], "rendered tree:\n" + depthOne.joined(separator: "\n"))
    }

    func testTreeFullPathFlagPrintsAbsolutePaths() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let walkRN = try await recnum(volume, "/walk")

        var lines: [String] = []
        _ = try await Tree.render(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            maxDepth: Int.max, fullPath: true
        ) { lines.append($0) }

        XCTAssertTrue(lines.contains { $0.hasSuffix("/walk/a/b/deep.txt") },
                      "rendered tree:\n" + lines.joined(separator: "\n"))
    }

    /// The whole-volume walk terminates despite the root's `.` self-entry, and
    /// annotates it rather than following it.
    func testTreeOverVolumeRootHandlesSelfEntry() async throws {
        let image = try mutableFixtureCopy()
        let volume = try await openVolume(image)

        var lines: [String] = []
        let summary = try await Tree.render(
            source: volume, startRecordNumber: 5, rootPath: "/", maxDepth: Int.max
        ) { lines.append($0) }

        XCTAssertGreaterThan(summary.files, 0)
        XCTAssertEqual(summary.errors, 0)
        if lines.contains(where: { $0.contains("── ./") }) {
            XCTAssertTrue(lines.contains { $0.contains("── ./  [cycle: already visited]") },
                          "the root self-entry must be marked as a cycle")
        }
    }

    // MARK: - find

    func testFindLocatesDeeplyNestedFileByGlob() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)

        var hits: [String] = []
        let result = try await Find.search(
            source: volume,
            startRecordNumber: 5,
            rootPath: "/",
            pattern: "deep*",
            kind: nil,
            maxDepth: Int.max,
            onMatch: { hits.append($0) }
        )

        XCTAssertEqual(hits, ["/walk/a/b/deep.txt"])
        XCTAssertEqual(result, Find.Result(matches: 1, errors: 0))
    }

    func testFindTypeFilterSeparatesFilesFromDirectories() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let walkRN = try await recnum(volume, "/walk")

        var files: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            pattern: nil, kind: .f, maxDepth: Int.max,
            onMatch: { files.append($0) }
        )
        var directories: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            pattern: nil, kind: .d, maxDepth: Int.max,
            onMatch: { directories.append($0) }
        )

        XCTAssertEqual(files.sorted(), ["/walk/a/IMG_0001.jpg", "/walk/a/b/deep.txt", "/walk/top.txt"])
        XCTAssertEqual(directories.sorted(), ["/walk/a", "/walk/a/b", "/walk/empty"])
    }

    func testFindCaseSensitivityAndDepthBound() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let walkRN = try await recnum(volume, "/walk")

        // Case-insensitive by default (NTFS semantics).
        var insensitive: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            pattern: "img_*.JPG", kind: nil, maxDepth: Int.max,
            onMatch: { insensitive.append($0) }
        )
        XCTAssertEqual(insensitive, ["/walk/a/IMG_0001.jpg"])

        // --case-sensitive makes the same pattern miss.
        var sensitive: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            pattern: "img_*.JPG", kind: nil, caseSensitive: true, maxDepth: Int.max,
            onMatch: { sensitive.append($0) }
        )
        XCTAssertTrue(sensitive.isEmpty)

        // --depth 2 cannot reach /walk/a/b/deep.txt (depth 3).
        var shallow: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: walkRN, rootPath: "/walk",
            pattern: "*.txt", kind: nil, maxDepth: 2,
            onMatch: { shallow.append($0) }
        )
        XCTAssertEqual(shallow, ["/walk/top.txt"])
    }

    /// Paths stay volume-absolute when the walk root is given as an MFT record
    /// number instead of a path.
    func testWalkTargetResolvesRecordNumberToAbsolutePath() async throws {
        let image = try mutableFixtureCopy()
        try await seedTree(imagePath: image)
        let volume = try await openVolume(image)
        let aRN = try await recnum(volume, "/walk/a")

        let resolved = try await WalkTarget.resolve(String(aRN), volume: volume)
        XCTAssertEqual(resolved.recordNumber, aRN)
        XCTAssertEqual(resolved.path, "/walk/a")

        var hits: [String] = []
        _ = try await Find.search(
            source: volume, startRecordNumber: resolved.recordNumber, rootPath: resolved.path,
            pattern: "deep.txt", kind: nil, maxDepth: Int.max,
            onMatch: { hits.append($0) }
        )
        XCTAssertEqual(hits, ["/walk/a/b/deep.txt"])
    }

    // MARK: - Error containment through the consumers

    /// A source whose `bad` directory can't be read — the shape a corrupt
    /// `$I30` produces on a real volume, forged here so the CLI's rendering of
    /// a contained error is covered deterministically.
    private struct PartlyUnreadableSource: DirectoryChildSource {
        func directoryChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
            func entry(_ name: String, _ rn: UInt64, _ isDirectory: Bool) -> DirectoryEntry {
                DirectoryEntry(
                    fileReference: rn,
                    recordNumber: rn,
                    sequenceNumber: 1,
                    fileName: FileName(
                        parentDirectoryReference: 0, parentRecordNumber: 0, parentSequenceNumber: 0,
                        creationTime: nil, modificationTime: nil, mftChangeTime: nil, accessTime: nil,
                        allocatedSize: 0, realSize: 0,
                        fileAttributes: isDirectory ? 0x1000_0000 : 0,
                        namespace: .win32, name: name
                    )
                )
            }
            switch recordNumber {
            case 5:  return [entry("bad", 10, true), entry("good", 11, true), entry("tail.txt", 12, false)]
            case 10: throw NTFSError.corruptOnDisk(description: "$INDEX_ROOT:$I30 unreadable")
            case 11: return [entry("seen.txt", 21, false)]
            default: throw NTFSError.corruptOnDisk(description: "record \(recordNumber) is not a directory")
            }
        }
    }

    /// `tree` reports the unreadable node inline and still finishes the rest
    /// of the walk; the error is counted in the summary.
    func testTreeReportsUnreadableSubdirectoryAndContinues() async throws {
        var lines: [String] = []
        let summary = try await Tree.render(
            source: PartlyUnreadableSource(),
            startRecordNumber: 5,
            rootPath: "/",
            maxDepth: Int.max
        ) { lines.append($0) }

        XCTAssertEqual(lines, [
            "/",
            "├── bad/",
            "│   └── [error: corrupt: $INDEX_ROOT:$I30 unreadable]",
            "├── good/",
            "│   └── seen.txt",
            "└── tail.txt",
            "",
            "2 directories, 2 files, 1 error"
        ], "rendered tree:\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(summary, Tree.Summary(directories: 2, files: 2, errors: 1))
    }

    /// `find` routes the same failure to its error sink, keeps matching, and
    /// reports a non-zero error count (which drives the CLI's exit status).
    func testFindReportsUnreadableSubdirectoryAndContinues() async throws {
        var hits: [String] = []
        var errors: [String] = []
        let result = try await Find.search(
            source: PartlyUnreadableSource(),
            startRecordNumber: 5,
            rootPath: "/",
            pattern: "*",
            kind: nil,
            maxDepth: Int.max,
            onMatch: { hits.append($0) },
            onError: { errors.append($0) }
        )

        XCTAssertEqual(hits, ["/bad", "/good", "/good/seen.txt", "/tail.txt"])
        XCTAssertEqual(errors, ["/bad: corrupt: $INDEX_ROOT:$I30 unreadable"])
        XCTAssertEqual(result, Find.Result(matches: 4, errors: 1))
    }

    // MARK: - CLI wiring

    func testSubcommandsAreRegisteredAndParseTheirFlags() throws {
        let help = Ntfsctl.helpMessage()
        XCTAssertTrue(help.contains("tree"), "`tree` must appear in `ntfsctl --help`")
        XCTAssertTrue(help.contains("find"), "`find` must appear in `ntfsctl --help`")

        let tree = try Tree.parse(["disk.img", "/walk", "--depth", "2", "--full-path"])
        XCTAssertEqual(tree.device, "disk.img")
        XCTAssertEqual(tree.target, "/walk")
        XCTAssertEqual(tree.depth, 2)
        XCTAssertTrue(tree.fullPath)

        let find = try Find.parse(["disk.img", "--name", "*.jpg", "--type", "f", "--depth", "3"])
        XCTAssertEqual(find.device, "disk.img")
        XCTAssertEqual(find.target, "/", "default target is the volume root")
        XCTAssertEqual(find.name, "*.jpg")
        XCTAssertEqual(find.type, .f)
        XCTAssertEqual(find.depth, 3)

        XCTAssertThrowsError(try Tree.parse(["disk.img", "--depth", "0"]).validate(),
                             "--depth 0 must be rejected")
        XCTAssertThrowsError(try Find.parse(["disk.img", "--depth", "-1"]).validate(),
                             "negative --depth must be rejected")
        XCTAssertThrowsError(try Find.parse(["disk.img", "--type", "x"]),
                             "--type only accepts f or d")
    }
}
