import XCTest
@testable import NTFSCore

/// Tests for the ONE shared recursive `$I30` walker (`DirectoryWalker`) that
/// `ntfsctl tree` and `ntfsctl find` both consume.
///
/// Two kinds of coverage:
///  - **Synthetic trees** (`SyntheticTree`, `GeneratedTree`) for the shapes a
///    disk image can't easily host: an unreadable subdirectory, a 40k-node
///    corpus, a directory that points back at its ancestor.
///  - **Real fixture walks** over `small.img`, including a genuine ON-DISK
///    cycle forged with `rename`, plus a cross-check that the walker's counts
///    match an independent `enumerate`-based reference walk.
final class DirectoryWalkerTests: XCTestCase {

    // MARK: - Synthetic sources

    /// In-memory `$I30` table. `failing` record numbers throw on read, which
    /// is how "unreadable subdirectory" is modelled.
    private actor SyntheticTree: DirectoryChildSource {
        private let table: [UInt64: [DirectoryEntry]]
        private let failing: Set<UInt64>
        private(set) var reads: [UInt64] = []

        init(table: [UInt64: [DirectoryEntry]], failing: Set<UInt64> = []) {
            self.table = table
            self.failing = failing
        }

        func directoryChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
            reads.append(recordNumber)
            if failing.contains(recordNumber) {
                throw NTFSError.corruptOnDisk(description: "unreadable $I30 in record \(recordNumber)")
            }
            guard let children = table[recordNumber] else {
                throw NTFSError.corruptOnDisk(description: "record \(recordNumber) is not a directory")
            }
            return children
        }

        func recordedReads() -> [UInt64] { reads }
    }

    /// A large tree generated on demand — never materialized as a whole, so
    /// the *source* can't be what blows memory in the streaming test.
    private struct GeneratedTree: DirectoryChildSource {
        let directoryCount: Int
        let filesPerDirectory: Int

        var totalNodes: Int { directoryCount + directoryCount * filesPerDirectory }

        func directoryChildren(of recordNumber: UInt64) async throws -> [DirectoryEntry] {
            if recordNumber == 5 {
                return (0..<directoryCount).map {
                    DirectoryWalkerTests.makeEntry(
                        name: "dir\($0)", recordNumber: 1_000 + UInt64($0), isDirectory: true
                    )
                }
            }
            guard recordNumber >= 1_000, recordNumber < 1_000 + UInt64(directoryCount) else {
                throw NTFSError.corruptOnDisk(description: "record \(recordNumber) is not a directory")
            }
            return (0..<filesPerDirectory).map {
                DirectoryWalkerTests.makeEntry(
                    name: "file\($0).bin",
                    recordNumber: recordNumber * 10_000 + UInt64($0),
                    isDirectory: false
                )
            }
        }
    }

    // MARK: - Entry construction

    private static func makeEntry(
        name: String,
        recordNumber: UInt64,
        isDirectory: Bool,
        namespace: FileName.Namespace = .win32
    ) -> DirectoryEntry {
        DirectoryEntry(
            fileReference: (UInt64(1) << 48) | recordNumber,
            recordNumber: recordNumber,
            sequenceNumber: 1,
            fileName: FileName(
                parentDirectoryReference: 0,
                parentRecordNumber: 0,
                parentSequenceNumber: 0,
                creationTime: nil,
                modificationTime: nil,
                mftChangeTime: nil,
                accessTime: nil,
                allocatedSize: 0,
                realSize: 0,
                // 0x10000000 = NTFS FILE_NAME_INDEX_PRESENT (the directory bit).
                fileAttributes: isDirectory ? 0x1000_0000 : 0,
                namespace: namespace,
                name: name
            )
        )
    }

    // MARK: - Collection helper (test-side accumulation is fine; the walker's isn't)

    private func collect(
        _ source: some DirectoryChildSource,
        from start: UInt64 = 5,
        rootPath: String = "/",
        maxDepth: Int = Int.max
    ) async throws -> (entries: [WalkedNode], failures: [WalkFailure]) {
        var entries: [WalkedNode] = []
        var failures: [WalkFailure] = []
        try await DirectoryWalker(source: source)
            .walk(from: start, rootPath: rootPath, maxDepth: maxDepth) { event in
                switch event {
                case let .entry(node): entries.append(node)
                case let .failure(failure): failures.append(failure)
                }
            }
        return (entries, failures)
    }

    // MARK: - Ordering / paths

    /// Depth-first pre-order, `$I30` order preserved, paths built from the
    /// walk root, depths 1-based, `isLastChild` set on each level's final entry.
    func testWalkIsDepthFirstPreOrderWithFullPaths() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("a", 10, true, .win32), e("z.txt", 11, false, .win32)],
            10: [e("b", 20, true, .win32), e("a.txt", 21, false, .win32)],
            20: [e("deep.txt", 30, false, .win32)]
        ])

        let (entries, failures) = try await collect(tree)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(entries.map(\.path),
                       ["/a", "/a/b", "/a/b/deep.txt", "/a/a.txt", "/z.txt"],
                       "pre-order: a directory's subtree is emitted before its next sibling")
        XCTAssertEqual(entries.map(\.depth), [1, 2, 3, 2, 1])
        XCTAssertEqual(entries.map(\.isLastChild), [false, false, true, true, true])
        XCTAssertEqual(entries.first?.parentPath, "/")
        XCTAssertEqual(entries[2].parentPath, "/a/b")
        XCTAssertEqual(entries[2].parentRecordNumber, 20)
    }

    /// A walk rooted at a subdirectory still emits volume-absolute paths.
    func testWalkRootPathPrefixesEveryEmittedPath() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            40: [e("sub", 41, true, .win32)],
            41: [e("leaf.txt", 42, false, .win32)]
        ])

        let (entries, _) = try await collect(tree, from: 40, rootPath: "gallery/Android/")

        XCTAssertEqual(entries.map(\.path), ["/gallery/Android/sub", "/gallery/Android/sub/leaf.txt"])
    }

    /// DOS 8.3 aliases are dropped so a file never appears twice — matching
    /// what `ntfsctl list` shows.
    func testDOSNamespaceAliasesAreFiltered() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("LONGFI~1.TXT", 12, false, .dos), e("LongFileName.txt", 12, false, .win32)]
        ])

        let (entries, _) = try await collect(tree)

        XCTAssertEqual(entries.map(\.name), ["LongFileName.txt"])
    }

    // MARK: - Depth bounding

    /// `--depth N` stops at N *and* never pays the I/O for level N+1: the
    /// bound is honoured BEFORE descending.
    func testDepthBoundIsHonouredBeforeDescending() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("l1", 10, true, .win32)],
            10: [e("l2", 20, true, .win32)],
            20: [e("l3", 30, true, .win32)],
            30: [e("bottom.txt", 40, false, .win32)]
        ])

        let (entries, failures) = try await collect(tree, maxDepth: 2)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(entries.map(\.path), ["/l1", "/l1/l2"])
        XCTAssertEqual(entries.last?.stoppedAtDepthLimit, true,
                       "the directory sitting at the limit is reported but not descended")
        let reads = await tree.recordedReads()
        XCTAssertEqual(reads, [5, 10],
                       "record 20 must never be read — the depth check precedes the child read")
    }

    /// Depth 1 = immediate children only. A zero/negative bound yields nothing
    /// (the CLI rejects it before we get here).
    func testDepthOneEmitsOnlyImmediateChildren() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("d", 10, true, .win32), e("f.txt", 11, false, .win32)],
            10: [e("hidden.txt", 20, false, .win32)]
        ])

        let (entries, _) = try await collect(tree, maxDepth: 1)
        XCTAssertEqual(entries.map(\.path), ["/d", "/f.txt"])

        let (none, _) = try await collect(tree, maxDepth: 0)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Cycle / revisit safety

    /// A directory whose `$I30` points back at its ancestor terminates: the
    /// repeat is reported once with `isCycle` and never re-entered.
    func testAncestorCycleTerminatesAndIsFlagged() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("a", 10, true, .win32)],
            10: [e("b", 20, true, .win32)],
            20: [e("back-to-a", 10, true, .win32), e("leaf.txt", 30, false, .win32)]
        ])

        let (entries, failures) = try await collect(tree)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(entries.map(\.path), ["/a", "/a/b", "/a/b/back-to-a", "/a/b/leaf.txt"])
        XCTAssertEqual(entries[2].isCycle, true)
        let reads = await tree.recordedReads()
        XCTAssertEqual(reads, [5, 10, 20], "record 10 must be enumerated exactly once")
    }

    /// A self-referencing directory (the shape NTFS roots actually have — the
    /// `.` entry) is caught by the same guard.
    func testSelfReferenceIsFlaggedNotFollowed() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e(".", 5, true, .win32), e("x.txt", 11, false, .win32)]
        ])

        let (entries, _) = try await collect(tree)

        XCTAssertEqual(entries.map(\.path), ["/.", "/x.txt"])
        XCTAssertEqual(entries[0].isCycle, true)
    }

    /// The same directory reachable from two parents is expanded once; the
    /// second sighting is reported (nothing is silently dropped) but not
    /// re-walked.
    func testRevisitedDirectoryIsExpandedOnlyOnce() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("p", 10, true, .win32), e("q", 11, true, .win32)],
            10: [e("shared", 20, true, .win32)],
            11: [e("shared", 20, true, .win32)],
            20: [e("only-once.txt", 30, false, .win32)]
        ])

        let (entries, _) = try await collect(tree)

        XCTAssertEqual(entries.filter { $0.name == "only-once.txt" }.count, 1)
        XCTAssertEqual(entries.filter { $0.name == "shared" }.map(\.isCycle), [false, true])
    }

    // MARK: - Error containment

    /// An unreadable subdirectory produces a failure for THAT node only; its
    /// siblings and their subtrees still complete.
    func testUnreadableSubdirectoryIsContainedAndWalkContinues() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(
            table: [
                5: [e("bad", 10, true, .win32), e("good", 11, true, .win32), e("tail.txt", 12, false, .win32)],
                10: [e("never-seen.txt", 20, false, .win32)],
                11: [e("seen.txt", 21, false, .win32)]
            ],
            failing: [10]
        )

        let (entries, failures) = try await collect(tree)

        XCTAssertEqual(entries.map(\.path), ["/bad", "/good", "/good/seen.txt", "/tail.txt"],
                       "the failing node is still reported, and the rest of the walk completes")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].path, "/bad")
        XCTAssertEqual(failures[0].recordNumber, 10)
        XCTAssertEqual(failures[0].depth, 1)
        XCTAssertTrue(failures[0].reason.contains("unreadable $I30"), "reason: \(failures[0].reason)")
    }

    /// Failures arrive immediately after their directory's own entry — the
    /// ordering `tree`'s renderer relies on to attach `[error: …]` inline.
    func testFailureEventFollowsItsDirectoryEntry() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(
            table: [5: [e("bad", 10, true, .win32), e("after.txt", 11, false, .win32)]],
            failing: [10]
        )

        var order: [String] = []
        try await DirectoryWalker(source: tree).walk(from: 5) { event in
            switch event {
            case let .entry(node): order.append("entry:\(node.path)")
            case let .failure(failure): order.append("failure:\(failure.path)")
            }
        }

        XCTAssertEqual(order, ["entry:/bad", "failure:/bad", "entry:/after.txt"])
    }

    /// If the walk ROOT itself is unreadable there is nothing to contain the
    /// error to: one failure, no entries, no hang.
    func testUnreadableRootReportsSingleFailure() async throws {
        let tree = SyntheticTree(table: [:], failing: [5])

        let (entries, failures) = try await collect(tree)

        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].depth, 0)
        XCTAssertEqual(failures[0].path, "/")
    }

    // MARK: - Streaming

    /// Consumers see events as they are produced: at the first emitted entry
    /// exactly ONE directory has been read. A walker that built the tree first
    /// would have read all of them before emitting anything.
    func testFirstEventArrivesBeforeTheTreeIsRead() async throws {
        let e = Self.makeEntry
        let tree = SyntheticTree(table: [
            5: [e("a", 10, true, .win32), e("b", 11, true, .win32)],
            10: [e("x.txt", 20, false, .win32)],
            11: [e("y.txt", 21, false, .win32)]
        ])

        var readsAtFirstEvent: Int?
        try await DirectoryWalker(source: tree).walk(from: 5) { _ in
            if readsAtFirstEvent == nil {
                readsAtFirstEvent = await tree.recordedReads().count
            }
        }

        XCTAssertEqual(readsAtFirstEvent, 2,
                       "only the root and the first directory are read before the first emit")
        let reads = await tree.recordedReads()
        XCTAssertEqual(reads.count, 3, "all three directories are read by the end")
    }

    /// A 100,500-node walk must not grow resident memory anywhere near the
    /// size of the tree — live state is one frame per level of the CURRENT
    /// path. (The 22,419-file corpus is the real-world case this protects.)
    ///
    /// The same walk is then re-run with an accumulating consumer as a CONTROL,
    /// so the threshold is proven discriminating rather than merely generous:
    /// retaining every node costs tens of MiB, streaming costs ~nothing.
    func testLargeWalkDoesNotAccumulateTheTree() async throws {
        let tree = GeneratedTree(directoryCount: 500, filesPerDirectory: 200)
        guard let before = residentBytes() else { throw XCTSkip("no RSS reporting on this platform") }

        var count = 0
        var deepestDepth = 0
        try await DirectoryWalker(source: tree).walk(from: 5) { event in
            if case let .entry(node) = event {
                count += 1
                deepestDepth = max(deepestDepth, node.depth)
            }
        }

        guard let afterStreaming = residentBytes() else { throw XCTSkip("no RSS reporting on this platform") }
        XCTAssertEqual(count, tree.totalNodes, "every node is visited")
        XCTAssertEqual(deepestDepth, 2)

        let streamingGrowth = afterStreaming > before ? afterStreaming - before : 0
        XCTAssertLessThan(streamingGrowth, 8 << 20,
                          "resident growth \(streamingGrowth) B over a \(tree.totalNodes)-node walk suggests accumulation")

        // CONTROL: hold every node and watch the same walk cost real memory.
        var retained: [WalkedNode] = []
        try await DirectoryWalker(source: tree).walk(from: 5) { event in
            if case let .entry(node) = event { retained.append(node) }
        }
        guard let afterAccumulating = residentBytes() else { throw XCTSkip("no RSS reporting on this platform") }
        let accumulatingGrowth = afterAccumulating > afterStreaming ? afterAccumulating - afterStreaming : 0
        XCTAssertEqual(retained.count, tree.totalNodes)
        XCTAssertGreaterThan(accumulatingGrowth, streamingGrowth + (8 << 20),
                             "control: accumulating the tree must cost far more than streaming it " +
                             "(streaming \(streamingGrowth) B vs accumulating \(accumulatingGrowth) B) — " +
                             "otherwise the streaming bound above proves nothing")
    }

    private func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : nil
        #else
        return nil
        #endif
    }

    // MARK: - Real fixture walks

    private func fixtureExists(_ name: String) -> Bool {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Independent reference walk built directly on `Volume.enumerate` — the
    /// oracle the walker is checked against (this is the "`list` by hand at
    /// every level" the walker replaces).
    private func referenceWalk(
        volume: Volume,
        from start: UInt64,
        rootPath: String = "/",
        maxDepth: Int
    ) async throws -> [String] {
        var out: [String] = []
        var visited: Set<UInt64> = [start]

        func descend(_ recordNumber: UInt64, _ path: String, _ depth: Int) async throws {
            guard depth <= maxDepth else { return }
            let children = try await volume.enumerate(directory: recordNumber)
                .filter { $0.fileName.namespace != .dos }
            for child in children {
                let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
                out.append(childPath)
                if child.isDirectory, visited.insert(child.recordNumber).inserted {
                    try await descend(child.recordNumber, childPath, depth + 1)
                }
            }
        }
        try await descend(start, rootPath, 1)
        return out
    }

    /// The walker's output over a real volume matches an independent
    /// `enumerate`-based walk, unbounded and at every depth bound.
    func testFixtureWalkMatchesIndependentEnumerateWalk() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        for depth in [1, 2, Int.max] {
            let (entries, failures) = try await collect(volume, maxDepth: depth)
            let reference = try await referenceWalk(volume: volume, from: 5, maxDepth: depth)
            XCTAssertTrue(failures.isEmpty, "unexpected failures at depth \(depth): \(failures)")
            XCTAssertEqual(entries.map(\.path), reference, "walker/reference divergence at depth \(depth)")
            XCTAssertFalse(entries.isEmpty)
        }
    }

    /// The `small.img` root has a `.` self-entry, so the real fixture already
    /// exercises the revisit guard: root is enumerated exactly once.
    func testFixtureRootSelfEntryIsNotFollowed() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let (entries, _) = try await collect(volume)
        let dot = entries.filter { $0.name == "." }
        if dot.isEmpty { throw XCTSkip("fixture root has no '.' entry") }
        XCTAssertEqual(dot.map(\.isCycle), [true])
        XCTAssertEqual(entries.filter { $0.path.hasPrefix("/./") }.count, 0,
                       "nothing may be walked THROUGH the self-entry")
    }

    /// A genuine ON-DISK cycle: move a directory into its own child, so
    /// `/cyc/inner` and `/cyc` reference each other. The walk terminates.
    func testOnDiskDirectoryCycleTerminates() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let writer = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false))
        try await writer.beginWriteSession()
        let outer = try await writer.createFile(named: "cyc", inDirectory: 5, isDirectory: true)
        let inner = try await writer.createFile(named: "inner", inDirectory: outer, isDirectory: true)
        _ = try await writer.createFile(named: "leaf.txt", inDirectory: inner, isDirectory: false)
        // Move `cyc` INTO its own child: inner's $I30 now lists cyc, and cyc's
        // $I30 still lists inner — a two-node loop on disk.
        try await writer.rename(at: outer, toName: "cyc", inDirectory: inner)
        try await writer.endWriteSession()

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        var entries: [WalkedNode] = []
        // Bounded by an XCTest expectation-free hard cap: if the guard were
        // missing this walk would never end, so cap the collected count and
        // fail loudly rather than hang the suite forever.
        try await DirectoryWalker(source: volume).walk(from: outer, rootPath: "/cyc") { event in
            if case let .entry(node) = event {
                entries.append(node)
                if entries.count > 100 {
                    struct Runaway: Error {}
                    throw Runaway()
                }
            }
        }

        XCTAssertEqual(entries.map(\.path), ["/cyc/inner", "/cyc/inner/cyc", "/cyc/inner/leaf.txt"])
        XCTAssertEqual(entries[1].isCycle, true, "the back-edge to the walk root is flagged, not followed")
    }

    /// `absolutePath(of:)` reconstructs the volume-absolute path from the
    /// parent chain — how `tree`/`find` label a record-number target.
    func testAbsolutePathReconstructsFromParentChain() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let writer = try await Volume(device: try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false))
        try await writer.beginWriteSession()
        let dir = try await writer.createFile(named: "abs", inDirectory: 5, isDirectory: true)
        let file = try await writer.createFile(named: "deep.txt", inDirectory: dir, isDirectory: false)
        try await writer.endWriteSession()

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        let rootPath = try await volume.absolutePath(of: 5)
        let dirPath = try await volume.absolutePath(of: dir)
        let filePath = try await volume.absolutePath(of: file)

        XCTAssertEqual(rootPath, "/")
        XCTAssertEqual(dirPath, "/abs")
        XCTAssertEqual(filePath, "/abs/deep.txt")
    }
}
