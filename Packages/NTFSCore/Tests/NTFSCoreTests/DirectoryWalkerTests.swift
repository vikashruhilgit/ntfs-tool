import XCTest
@testable import NTFSCore

/// Tests for the single shared recursive `$I30` walker that `ntfsctl tree`
/// and `ntfsctl find` both consume.
///
/// The four properties the walker is required to have — depth bounding,
/// cycle/revisit safety, per-node error containment, and streaming (no
/// whole-tree accumulation) — each get a test here. Two of them need a
/// deliberately damaged fixture, built from a throwaway copy of `small.img`:
///  - the cycle is made with `rename`, which has no "move a directory into
///    its own descendant" guard, so the resulting `$I30` graph really does
///    loop (this is the same shape a corrupt volume would present);
///  - the unreadable subdirectory is made by clearing the DIRECTORY bit in
///    the child's own MFT record header while the parent's `$I30` entry
///    still advertises it as a directory — so the walker descends and
///    `enumerate` throws, which is exactly the containment path.
final class DirectoryWalkerTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Drain a walker completely, with a hard iteration cap so a
    /// non-terminating walk fails the test instead of hanging the suite.
    private func drain(
        _ walker: DirectoryWalker,
        cap: Int = 10_000
    ) async throws -> (entries: [WalkEntry], errors: [WalkError]) {
        var entries: [WalkEntry] = []
        var errors: [WalkError] = []
        var pulls = 0
        while let event = await walker.next() {
            pulls += 1
            if pulls > cap {
                XCTFail("walker did not terminate within \(cap) events — cycle safety failed")
                break
            }
            switch event {
            case .entry(let e): entries.append(e)
            case .error(let e): errors.append(e)
            }
        }
        return (entries, errors)
    }

    // MARK: - Depth bounding (AC2)

    /// maxDepth 1 must yield exactly the root's own children — the same set
    /// `enumerate` returns directly, DOS aliases excluded.
    func testDepthOneMatchesDirectEnumerate() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let expected = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos && $0.name != "." }
            .map(\.name)
            .sorted()

        let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 1)
        let (entries, errors) = try await drain(walker)

        XCTAssertEqual(entries.map(\.name).sorted(), expected)
        XCTAssertTrue(errors.isEmpty, "clean fixture should produce no walk errors")
        XCTAssertTrue(entries.allSatisfy { $0.depth == 1 }, "maxDepth 1 must not emit anything below depth 1")
    }

    /// maxDepth 2 must equal an independent, hand-written two-level walk —
    /// the "counts match an independent `list` walk" acceptance criterion,
    /// asserted at the walker level.
    func testDepthTwoMatchesIndependentTwoLevelWalk() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        // Independent oracle: enumerate root, then enumerate each child dir.
        // No use of DirectoryWalker at all.
        var expected: [String] = []
        let level1 = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos && $0.name != "." }
        for entry in level1 {
            expected.append("/" + entry.name)
            guard entry.isDirectory else { continue }
            let level2 = try await volume.enumerate(directory: entry.recordNumber)
                .filter { $0.fileName.namespace != .dos && $0.name != "." }
            for child in level2 {
                expected.append("/" + entry.name + "/" + child.name)
            }
        }

        let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 2)
        let (entries, _) = try await drain(walker)

        XCTAssertEqual(entries.map(\.path).sorted(), expected.sorted())
        XCTAssertTrue(entries.allSatisfy { $0.depth <= 2 })

        // Counts, the way `tree`'s summary computes them.
        let dirCount = entries.filter(\.isDirectory).count
        let fileCount = entries.count - dirCount
        XCTAssertEqual(dirCount + fileCount, expected.count)
    }

    /// maxDepth 0 means "don't even list the root's children".
    func testDepthZeroYieldsNothing() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 0)
        let (entries, errors) = try await drain(walker)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - Deep paths (AC3 producer half)

    /// A deeply-nested file must be reported at its correct full path.
    func testDeeplyNestedFileGetsCorrectFullPath() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))

        let a = try await volume.createFile(named: "aa", inDirectory: 5, isDirectory: true)
        let b = try await volume.createFile(named: "bb", inDirectory: a, isDirectory: true)
        let c = try await volume.createFile(named: "cc", inDirectory: b, isDirectory: true)
        _ = try await volume.createFile(named: "deep.txt", inDirectory: c)

        let walker = DirectoryWalker(volume: volume, root: 5)
        let (entries, errors) = try await drain(walker)

        XCTAssertTrue(errors.isEmpty, "unexpected walk errors: \(errors.map(\.message))")
        let deep = entries.first { $0.name == "deep.txt" }
        XCTAssertEqual(deep?.path, "/aa/bb/cc/deep.txt")
        XCTAssertEqual(deep?.depth, 4)
        XCTAssertEqual(deep?.isDirectory, false)
    }

    // MARK: - Cycle safety (AC4)

    /// A `$I30` graph containing a real directory cycle must terminate and
    /// visit each directory record at most once.
    func testDirectoryCycleTerminates() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))

        // Build /outer/inner, then move `outer` INTO `inner`. `outer`'s $I30
        // still lists `inner`, and `inner`'s $I30 now lists `outer` — a real
        // on-disk cycle.
        let outer = try await volume.createFile(named: "outer", inDirectory: 5, isDirectory: true)
        let inner = try await volume.createFile(named: "inner", inDirectory: outer, isDirectory: true)
        _ = try await volume.createFile(named: "leaf.txt", inDirectory: inner)
        try await volume.rename(at: outer, toName: "outer", inDirectory: inner)

        // Walk starting AT `outer` so the cycle is reachable.
        let walker = DirectoryWalker(volume: volume, root: outer, basePath: "/outer")
        let (entries, _) = try await drain(walker, cap: 500)

        // Terminated (drain would have XCTFail'd otherwise). Each directory
        // record is descended at most once, so `inner` appears once and the
        // walk does not spiral.
        let innerVisits = entries.filter { $0.entry.recordNumber == inner }.count
        XCTAssertEqual(innerVisits, 1, "inner should be reached exactly once despite the cycle")
        XCTAssertTrue(
            entries.contains { $0.name == "leaf.txt" },
            "the cycle must not prevent the rest of the subtree from being walked"
        )
        // `outer` is re-encountered through the cycle: it is yielded as an
        // entry but must NOT be descended a second time.
        let outerEntries = entries.filter { $0.entry.recordNumber == outer }
        XCTAssertLessThanOrEqual(outerEntries.count, 1)
    }

    // MARK: - Error containment (AC5)

    /// One unreadable subdirectory produces one error event; every sibling
    /// and unrelated subtree is still walked, and the walk does not throw.
    func testUnreadableSubdirectoryIsContainedAndWalkContinues() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))

        let broken = try await volume.createFile(named: "broken", inDirectory: 5, isDirectory: true)
        _ = try await volume.createFile(named: "lost.txt", inDirectory: broken)
        let healthy = try await volume.createFile(named: "healthy", inDirectory: 5, isDirectory: true)
        _ = try await volume.createFile(named: "kept.txt", inDirectory: healthy)

        // Damage `broken`: clear the DIRECTORY bit in its MFT record header
        // (flags, offset 22) while the root's $I30 entry still says it is a
        // directory. `enumerate` then rejects it and the walker must contain
        // that failure. Offset 22 is nowhere near a sector-tail USA slot, so
        // patching it in place keeps the record's fix-ups valid.
        try clearDirectoryFlag(imagePath: path, volume: volume, recordNumber: broken)

        let reopened = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        let walker = DirectoryWalker(volume: reopened, root: 5)
        let (entries, errors) = try await drain(walker)

        XCTAssertEqual(errors.count, 1, "expected exactly one contained error, got \(errors.map(\.message))")
        XCTAssertEqual(errors.first?.path, "/broken")
        XCTAssertEqual(errors.first?.recordNumber, broken)
        XCTAssertEqual(errors.first?.depth, 2, "a failed descent is reported at the child's depth, not depth 0")

        // The rest of the volume still walked to completion.
        XCTAssertTrue(entries.contains { $0.path == "/healthy/kept.txt" },
                      "sibling subtree must still be walked")
        XCTAssertTrue(entries.contains { $0.path == "/hello.txt" },
                      "pre-existing root entries must still be walked")
        XCTAssertTrue(entries.contains { $0.path == "/broken" },
                      "the damaged directory itself is still reported as an entry")
        XCTAssertFalse(entries.contains { $0.path == "/broken/lost.txt" },
                       "nothing below the unreadable node can be reported")
    }

    /// An unreadable WALK ROOT is not a contained per-node error — it is a
    /// usage error, reported at depth 0 so consumers can exit non-zero the
    /// way `ntfsctl list` does for a bad path.
    func testUnreadableWalkRootIsReportedAtDepthZero() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        // hello.txt is a file, not a directory — walking it must fail at the root.
        let root = try await volume.enumerate(directory: 5)
        guard let hello = root.first(where: { $0.name == "hello.txt" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain hello.txt")
        }

        let walker = DirectoryWalker(volume: volume, root: hello.recordNumber, basePath: "/hello.txt")
        let (entries, errors) = try await drain(walker)

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.depth, 0, "walk-root failure must be distinguishable from a per-node failure")
    }

    // MARK: - Streaming (AC6)

    /// The discriminating streaming assertion: after exactly ONE pull on a
    /// deep tree, only the root frame is retained. An implementation that
    /// buffered the whole tree up front would have descended to full depth
    /// (or unwound to zero) before handing out its first event.
    func testFirstPullRetainsOnlyTheRootFrame() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))

        var parent: UInt64 = 5
        for level in 0..<5 {
            parent = try await volume.createFile(named: "lvl\(level)", inDirectory: parent, isDirectory: true)
        }
        _ = try await volume.createFile(named: "bottom.txt", inDirectory: parent)

        let walker = DirectoryWalker(volume: volume, root: 5)
        let beforeFirstPull = await walker.frameDepth
        XCTAssertEqual(beforeFirstPull, 0, "no frames retained before the first pull")
        _ = await walker.next()
        let afterFirstPull = await walker.frameDepth
        XCTAssertEqual(afterFirstPull, 1,
                       "after one pull the walker must hold only the root frame, not a buffered tree")
    }

    /// Across a full walk, retained frames never exceed the depth bound —
    /// memory is O(depth), not O(entries visited).
    func testFrameDepthNeverExceedsMaxDepthDuringFullWalk() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path))

        var parent: UInt64 = 5
        for level in 0..<6 {
            parent = try await volume.createFile(named: "d\(level)", inDirectory: parent, isDirectory: true)
            _ = try await volume.createFile(named: "f\(level).txt", inDirectory: parent)
        }

        let maxDepth = 4
        let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: maxDepth)
        var observed = 0
        var pulls = 0
        while let event = await walker.next() {
            pulls += 1
            XCTAssertTrue(pulls < 10_000, "walk did not terminate")
            observed = max(observed, await walker.frameDepth)
            if case .entry(let e) = event {
                XCTAssertLessThanOrEqual(e.depth, maxDepth)
            }
        }
        XCTAssertLessThanOrEqual(observed, maxDepth,
                                 "retained frames must be bounded by depth, not by entries visited")
        XCTAssertGreaterThan(pulls, maxDepth, "sanity: the walk actually visited a non-trivial tree")
    }

    // MARK: - Sibling flags (tree rendering support)

    /// The walker answers "is this the last child of its parent?" so a
    /// renderer can draw connectors without buffering siblings.
    func testIsLastSiblingMarksFinalChildOfEachDirectory() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let expectedLast = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos && $0.name != "." }
            .last?.name

        let walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 1)
        let (entries, _) = try await drain(walker)

        let flagged = entries.filter(\.isLastSibling).map(\.name)
        XCTAssertEqual(flagged.count, 1, "exactly one child of the root is the last sibling")
        XCTAssertEqual(flagged.first, expectedLast)
    }

    // MARK: - Fixture damage helper

    /// Clear the DIRECTORY bit (0x0002) in an MFT record's header flags
    /// field, in place on the image. The parent's `$I30` entry is untouched,
    /// so the directory is still advertised but no longer readable.
    private func clearDirectoryFlag(
        imagePath: String,
        volume: Volume,
        recordNumber: UInt64
    ) throws {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let mftStart = volume.boot.mftCluster * UInt64(volume.bytesPerCluster)
        let flagsOffset = mftStart + recordNumber * recordSize + 22  // MFTRecord.flags

        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: imagePath))
        defer { try? handle.close() }
        try handle.seek(toOffset: flagsOffset)
        guard let raw = try handle.read(upToCount: 2), raw.count == 2 else {
            throw XCTSkip("could not read MFT record flags at offset \(flagsOffset)")
        }
        var flags = UInt16(raw[raw.startIndex]) | (UInt16(raw[raw.startIndex + 1]) << 8)
        XCTAssertEqual(flags & 0x0002, 0x0002, "record \(recordNumber) should start out flagged as a directory")
        flags &= ~UInt16(0x0002)
        try handle.seek(toOffset: flagsOffset)
        try handle.write(contentsOf: Data([UInt8(flags & 0xFF), UInt8(flags >> 8)]))
        try handle.synchronize()
    }
}
