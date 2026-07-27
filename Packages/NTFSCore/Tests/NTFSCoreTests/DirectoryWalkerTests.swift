import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import NTFSCore

/// Coverage for the one shared recursive `$I30` walker (`DirectoryWalker`),
/// which `ntfsctl tree` and `ntfsctl find` both consume.
///
/// Most tests drive the walker through `DirectoryEnumerating` stubs rather
/// than `.img` fixtures — a directory cycle, a subdirectory that always throws,
/// and a ~350k-entry tree are all things that are either impossible or
/// impractical to commit as an on-disk image. The real-fixture and real
/// on-disk-cycle tests at the bottom of the file pin the stubs to reality.
final class DirectoryWalkerTests: XCTestCase {

    // MARK: - Stub sources

    /// Explicit in-memory directory graph. Records every `enumerate` call so
    /// tests can assert on the IO the walker actually performed (that is how
    /// "depth is honoured BEFORE descending" is proven).
    actor StubTree: DirectoryEnumerating {
        struct Child {
            let name: String
            let recordNumber: UInt64
            let isDirectory: Bool
            var namespace: FileName.Namespace = .win32

            static func dir(_ name: String, _ rn: UInt64) -> Child {
                Child(name: name, recordNumber: rn, isDirectory: true)
            }
            static func file(_ name: String, _ rn: UInt64) -> Child {
                Child(name: name, recordNumber: rn, isDirectory: false)
            }
            /// An 8.3 alias — a second `$I30` entry for the same record, which
            /// the walker must hide.
            static func dosAlias(_ name: String, _ rn: UInt64) -> Child {
                Child(name: name, recordNumber: rn, isDirectory: false, namespace: .dos)
            }
        }

        private var directories: [UInt64: [Child]] = [:]
        private var unreadable: Set<UInt64> = []
        private(set) var enumerateCalls: [UInt64] = []

        init(_ directories: [UInt64: [Child]] = [:]) {
            self.directories = directories
        }

        func define(_ recordNumber: UInt64, _ children: [Child]) {
            directories[recordNumber] = children
        }

        /// Make `recordNumber` throw when enumerated — the "unreadable
        /// subdirectory" case.
        func breakDirectory(_ recordNumber: UInt64) {
            unreadable.insert(recordNumber)
        }

        func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
            enumerateCalls.append(recordNumber)
            if unreadable.contains(recordNumber) {
                throw NTFSError.corruptOnDisk(
                    description: "stub: directory \(recordNumber) is unreadable"
                )
            }
            guard let children = directories[recordNumber] else {
                throw NTFSError.corruptOnDisk(description: "stub: no such directory \(recordNumber)")
            }
            return children.map {
                makeEntry(
                    name: $0.name,
                    recordNumber: $0.recordNumber,
                    isDirectory: $0.isDirectory,
                    namespace: $0.namespace
                )
            }
        }
    }

    /// Procedurally-generated k-ary tree — nothing is stored, so any memory
    /// growth observed during a walk belongs to the walker, not the source.
    ///
    /// Node ids use heap numbering (children of `i` are `i*k+1 … i*k+k`), MFT
    /// record number = id + 5, so the root is record 5. Nodes at
    /// `depth == fileDepth` are files; shallower nodes are directories.
    struct SyntheticTree: DirectoryEnumerating {
        let branching: Int
        let fileDepth: Int

        var directoryCount: Int {
            // (k^fileDepth - 1) / (k - 1) — the root included.
            (0..<fileDepth).reduce(0) { $0 + pow(branching, $1) }
        }
        var fileCount: Int { pow(branching, fileDepth) }
        /// Entries a full walk should yield: every node except the root.
        var entryCount: Int { directoryCount + fileCount - 1 }

        private func pow(_ base: Int, _ exponent: Int) -> Int {
            (0..<exponent).reduce(1) { acc, _ in acc * base }
        }

        private func depth(ofID id: Int) -> Int {
            var current = id, d = 0
            while current > 0 {
                current = (current - 1) / branching
                d += 1
            }
            return d
        }

        func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
            let id = Int(recordNumber) - 5
            let childDepth = depth(ofID: id) + 1
            guard childDepth <= fileDepth else {
                throw NTFSError.corruptOnDisk(description: "synthetic: record \(recordNumber) is a file")
            }
            return (1...branching).map { index in
                let childID = id * branching + index
                return makeEntry(
                    name: childDepth == fileDepth ? "f\(childID).bin" : "d\(childID)",
                    recordNumber: UInt64(childID + 5),
                    isDirectory: childDepth < fileDepth
                )
            }
        }
    }

    // MARK: - Collecting helper

    private struct Collected {
        var paths: [String] = []
        var depths: [String: Int] = [:]
        var lastSibling: Set<String> = []
        var revisited: [String] = []
        var failures: [DirectoryWalkFailure] = []
    }

    private func collect<Source: DirectoryEnumerating>(
        _ source: Source,
        from start: UInt64 = 5,
        rootPath: String = "/",
        maxDepth: Int? = nil
    ) async throws -> Collected {
        var out = Collected()
        try await DirectoryWalker(source: source)
            .walk(from: start, rootPath: rootPath, maxDepth: maxDepth) { event in
                switch event {
                case .entry(let node):
                    out.paths.append(node.path)
                    out.depths[node.path] = node.depth
                    if node.isLastSibling { out.lastSibling.insert(node.path) }
                    if node.isRevisitedDirectory { out.revisited.append(node.path) }
                case .failure(let failure):
                    out.failures.append(failure)
                }
            }
        return out
    }

    /// `/a` (dir) → `/a/b` (dir) → `/a/b/deep.txt`, plus `/a/one.txt` and a
    /// top-level `/z.txt`. Small enough to assert the full pre-order.
    private func sampleTree() async -> StubTree {
        let tree = StubTree()
        await tree.define(5,  [.dir("a", 20), .file("z.txt", 21)])
        await tree.define(20, [.dir("b", 30), .file("one.txt", 31)])
        await tree.define(30, [.file("deep.txt", 40)])
        return tree
    }

    // MARK: - Ordering / paths / depth

    func testWalkYieldsPreOrderPathsWithDepthAndSiblingFlags() async throws {
        let out = try await collect(await sampleTree())

        XCTAssertEqual(out.paths, [
            "/a", "/a/b", "/a/b/deep.txt", "/a/one.txt", "/z.txt"
        ], "pre-order: a directory is yielded before its children, in $I30 order")
        XCTAssertEqual(out.depths["/a"], 1)
        XCTAssertEqual(out.depths["/a/b"], 2)
        XCTAssertEqual(out.depths["/a/b/deep.txt"], 3)
        XCTAssertEqual(
            out.lastSibling.sorted(),
            ["/a/b/deep.txt", "/a/one.txt", "/z.txt"],
            "isLastSibling must be true only for the final child of each parent"
        )
        XCTAssertTrue(out.failures.isEmpty)
        XCTAssertTrue(out.revisited.isEmpty)
    }

    func testWalkFromNonRootStartRootsPathsAtThatDirectory() async throws {
        let out = try await collect(await sampleTree(), from: 20, rootPath: "/a")
        XCTAssertEqual(out.paths, ["/a/b", "/a/b/deep.txt", "/a/one.txt"])
        XCTAssertEqual(out.depths["/a/b"], 1, "depth is relative to the walk root")
    }

    func testTrailingSlashOnRootPathDoesNotDoubleUp() async throws {
        let out = try await collect(await sampleTree(), from: 20, rootPath: "/a/")
        XCTAssertEqual(out.paths.first, "/a/b")
    }

    func testDOSAliasesAndDotEntriesAreSkipped() async throws {
        // A root index as NTFS really has it: a "." self-link plus an 8.3 alias
        // for the same file as its Win32 name.
        let tree = StubTree()
        await tree.define(5, [
            .dir(".", 5),
            .dosAlias("LONGNA~1.TXT", 60),
            .file("LongName.txt", 60),
            .file("plain.txt", 61)
        ])

        let out = try await collect(tree)
        XCTAssertEqual(out.paths, ["/LongName.txt", "/plain.txt"])
    }

    // MARK: - Depth bounding

    func testMaxDepthStopsOutputAndIsCheckedBeforeDescending() async throws {
        let tree = await sampleTree()
        let out = try await collect(tree, maxDepth: 2)

        XCTAssertEqual(out.paths, ["/a", "/a/b", "/a/one.txt", "/z.txt"],
                       "nothing deeper than depth 2 may be reported, and depth-1 siblings still are")
        // The load-bearing half: /a/b sits AT the limit, so its contents must
        // never have been read. Enumerating it would be wasted IO on a real
        // volume (and would defeat `--depth` as a cost bound).
        let calls = await tree.enumerateCalls
        XCTAssertEqual(calls, [5, 20], "record 30 (/a/b) must not be enumerated at maxDepth 2")
    }

    func testMaxDepthOneYieldsOnlyDirectChildren() async throws {
        let tree = await sampleTree()
        let out = try await collect(tree, maxDepth: 1)
        XCTAssertEqual(out.paths, ["/a", "/z.txt"])
        let calls = await tree.enumerateCalls
        XCTAssertEqual(calls, [5], "only the start directory is read at maxDepth 1")
    }

    func testMaxDepthBelowOneYieldsNothingAndReadsNothing() async throws {
        let tree = await sampleTree()
        let out = try await collect(tree, maxDepth: 0)
        XCTAssertTrue(out.paths.isEmpty)
        let calls = await tree.enumerateCalls
        XCTAssertTrue(calls.isEmpty, "maxDepth 0 must not even read the start directory")
    }

    // MARK: - Cycle / revisit safety

    func testDirectoryCycleTerminatesAndIsReportedOnce() async throws {
        // /loop → /loop/inner → (back to /loop)
        let tree = StubTree()
        await tree.define(5,  [.dir("loop", 20)])
        await tree.define(20, [.dir("inner", 30)])
        await tree.define(30, [.dir("loop", 20), .file("leaf.txt", 40)])

        let out = try await collect(tree)

        XCTAssertEqual(out.paths, [
            "/loop", "/loop/inner", "/loop/inner/loop", "/loop/inner/leaf.txt"
        ])
        XCTAssertEqual(out.revisited, ["/loop/inner/loop"],
                       "the back-edge is reported once and flagged, not followed")
        let calls = await tree.enumerateCalls
        XCTAssertEqual(calls, [5, 20, 30], "each directory is enumerated exactly once")
    }

    func testSelfReferencingDirectoryTerminates() async throws {
        let tree = StubTree()
        await tree.define(5,  [.dir("self", 20)])
        await tree.define(20, [.dir("self", 20)])

        let out = try await collect(tree)
        XCTAssertEqual(out.paths, ["/self", "/self/self"])
        XCTAssertEqual(out.revisited, ["/self/self"])
    }

    func testStartDirectoryIsPreVisitedSoACycleBackToItTerminates() async throws {
        let tree = StubTree()
        await tree.define(5,  [.dir("a", 20)])
        await tree.define(20, [.dir("root-again", 5)])

        let out = try await collect(tree)
        XCTAssertEqual(out.paths, ["/a", "/a/root-again"])
        XCTAssertEqual(out.revisited, ["/a/root-again"])
        let calls = await tree.enumerateCalls
        XCTAssertEqual(calls, [5, 20])
    }

    func testHardLinkedDirectoryAppearingTwiceIsWalkedOnce() async throws {
        // Two distinct names for record 30 — not a cycle, but a revisit. The
        // second occurrence is listed and not re-descended.
        let tree = StubTree()
        await tree.define(5,  [.dir("first", 30), .dir("second", 30)])
        await tree.define(30, [.file("shared.txt", 40)])

        let out = try await collect(tree)
        XCTAssertEqual(out.paths, ["/first", "/first/shared.txt", "/second"])
        XCTAssertEqual(out.revisited, ["/second"])
    }

    // MARK: - Error containment

    func testUnreadableSubdirectoryIsReportedAndTheWalkContinues() async throws {
        let tree = StubTree()
        await tree.define(5,  [.dir("good", 20), .dir("bad", 21), .dir("later", 22)])
        await tree.define(20, [.file("in-good.txt", 30)])
        await tree.define(21, [.file("never-seen.txt", 31)])
        await tree.define(22, [.file("in-later.txt", 32)])
        await tree.breakDirectory(21)

        let out = try await collect(tree)

        XCTAssertEqual(out.paths, [
            "/good", "/good/in-good.txt",
            "/bad",                       // the node itself is still reported
            "/later", "/later/in-later.txt"  // and the walk keeps going
        ])
        XCTAssertEqual(out.failures.count, 1)
        let failure = try XCTUnwrap(out.failures.first)
        XCTAssertEqual(failure.path, "/bad")
        XCTAssertEqual(failure.recordNumber, 21)
        XCTAssertEqual(failure.depth, 1)
        XCTAssertTrue(failure.message.contains("unreadable"),
                      "the underlying error text must survive into the failure: \(failure.message)")
    }

    func testEveryChildDirectoryUnreadableStillCompletes() async throws {
        let tree = StubTree()
        await tree.define(5, [.dir("a", 20), .dir("b", 21)])
        await tree.define(20, [])
        await tree.define(21, [])
        await tree.breakDirectory(20)
        await tree.breakDirectory(21)

        let out = try await collect(tree)
        XCTAssertEqual(out.paths, ["/a", "/b"])
        XCTAssertEqual(out.failures.map(\.path), ["/a", "/b"])
    }

    func testUnreadableStartDirectoryThrows() async throws {
        // No walk to contain the error into — the caller must hear about it.
        let tree = StubTree()
        await tree.define(5, [])
        await tree.breakDirectory(5)

        do {
            _ = try await collect(tree)
            XCTFail("expected the start directory's error to propagate")
        } catch let error as NTFSError {
            XCTAssertEqual(error, .corruptOnDisk(description: "stub: directory 5 is unreadable"))
        }
    }

    func testVisitorErrorAbortsTheWalk() async throws {
        struct Stop: Error {}
        let tree = await sampleTree()
        var seen = 0
        do {
            try await DirectoryWalker(source: tree).walk(from: 5) { _ in
                seen += 1
                if seen == 2 { throw Stop() }
            }
            XCTFail("expected the visitor's error to propagate")
        } catch is Stop {
            XCTAssertEqual(seen, 2, "the walk stops at the throwing event")
        }
    }

    // MARK: - Streaming

    func testEventsAreDeliveredBeforeTheTreeIsFullyEnumerated() async throws {
        // The deterministic half of the streaming proof: a consumer that stops
        // after 10 entries must have caused only a handful of directory reads,
        // not a full traversal of the 349k-entry tree.
        struct Stop: Error {}
        let big = SyntheticTree(branching: 4, fileDepth: 9)
        let counting = CountingSource(wrapping: big)

        var seen = 0
        do {
            try await DirectoryWalker(source: counting).walk(from: 5) { _ in
                seen += 1
                if seen == 10 { throw Stop() }
            }
            XCTFail("expected to stop early")
        } catch is Stop {}

        let reads = await counting.calls
        XCTAssertEqual(seen, 10)
        XCTAssertLessThanOrEqual(reads, 12,
            "10 entries should cost a handful of directory reads; \(reads) suggests the walk " +
            "materialized the tree before yielding anything")
        XCTAssertLessThan(reads, big.directoryCount / 100)
    }

    func testWalkingALargeTreeDoesNotAccumulateIt() async throws {
        guard let baseline = Self.residentBytes() else {
            throw XCTSkip("resident-size reporting unavailable on this platform")
        }

        // 4^9 files + 87,380 directories ≈ 349k entries — an order of
        // magnitude past the 22,419-file corpus this has to survive.
        let big = SyntheticTree(branching: 4, fileDepth: 9)

        var streamed = 0
        var deepestSeen = 0
        try await DirectoryWalker(source: big).walk(from: 5) { event in
            if case .entry(let node) = event {
                streamed += 1
                deepestSeen = max(deepestSeen, node.depth)
            }
        }
        let afterStreaming = Self.residentBytes() ?? baseline
        let streamingGrowth = afterStreaming > baseline ? afterStreaming - baseline : 0

        XCTAssertEqual(streamed, big.entryCount, "the walk must be complete, not truncated")
        XCTAssertEqual(deepestSeen, big.fileDepth)

        // Calibration: the same walk while accumulating every node — i.e. what
        // "build the whole tree in memory" actually costs on this input. The
        // streaming walk has to be far cheaper than that, which is a claim
        // that holds regardless of allocator noise on this machine.
        var accumulated: [DirectoryWalkNode] = []
        try await DirectoryWalker(source: big).walk(from: 5) { event in
            if case .entry(let node) = event { accumulated.append(node) }
        }
        let afterAccumulating = Self.residentBytes() ?? afterStreaming
        let accumulatingGrowth = afterAccumulating > afterStreaming
            ? afterAccumulating - afterStreaming : 0
        XCTAssertEqual(accumulated.count, big.entryCount)

        let streamedMiB = Double(streamingGrowth) / 1_048_576
        let accumulatedMiB = Double(accumulatingGrowth) / 1_048_576
        print("[walker-memory] \(streamed) entries — streaming +\(String(format: "%.1f", streamedMiB)) MiB, accumulating +\(String(format: "%.1f", accumulatedMiB)) MiB")
        XCTAssertLessThan(streamingGrowth, 24 * 1_048_576,
            "streaming walk of \(streamed) entries grew resident memory by " +
            "\(String(format: "%.1f", streamedMiB)) MiB — expected < 24 MiB " +
            "(live set should be O(depth × siblings), not O(entries))")
        XCTAssertLessThan(streamingGrowth * 3, accumulatingGrowth,
            "streaming grew \(String(format: "%.1f", streamedMiB)) MiB vs " +
            "\(String(format: "%.1f", accumulatedMiB)) MiB for the accumulating walk — " +
            "the walker looks like it is retaining the tree")
    }

    /// Counts `enumerate` calls made against any source.
    actor CountingSource<Wrapped: DirectoryEnumerating>: DirectoryEnumerating {
        private let wrapped: Wrapped
        private(set) var calls = 0

        init(wrapping wrapped: Wrapped) { self.wrapped = wrapped }

        func enumerate(directory recordNumber: UInt64) async throws -> [DirectoryEntry] {
            calls += 1
            return try await wrapped.enumerate(directory: recordNumber)
        }
    }

    // MARK: - Real volume: fixture parity and an on-disk cycle

    /// The walker's output over the committed fixture must equal an
    /// independent, deliberately-duplicated recursive `enumerate` walk written
    /// here in the test (the oracle for "no traversal bugs").
    func testWalkMatchesAnIndependentRecursiveEnumerateOverTheFixture() async throws {
        let path = try fixturePath()
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let out = try await collect(volume)
        let oracle = try await Self.oracleWalk(volume: volume, directory: 5, prefix: "", maxDepth: nil)

        XCTAssertEqual(out.paths.sorted(), oracle.sorted())
        XCTAssertTrue(out.paths.contains("/sub/nested.txt"),
                      "fixture's nested file should be reached: \(out.paths)")
        XCTAssertTrue(out.failures.isEmpty, "\(out.failures)")
    }

    func testDepthBoundedWalkMatchesTheOracleOverTheFixture() async throws {
        let path = try fixturePath()
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        for limit in 1...3 {
            let out = try await collect(volume, maxDepth: limit)
            let oracle = try await Self.oracleWalk(volume: volume, directory: 5, prefix: "", maxDepth: limit)
            XCTAssertEqual(out.paths.sorted(), oracle.sorted(), "mismatch at --depth \(limit)")
            XCTAssertTrue(out.depths.values.allSatisfy { $0 <= limit })
        }
    }

    /// A REAL on-disk `$I30` cycle: `/cyc` is moved inside its own child
    /// `/cyc/inner`, so `cyc`'s index holds `inner` and `inner`'s index holds
    /// `cyc`. Walking from `cyc` must terminate.
    func testOnDiskDirectoryCycleTerminates() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let outer: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            outer = try await volume.createFile(named: "cyc", inDirectory: 5, isDirectory: true)
            let inner = try await volume.createFile(named: "inner", inDirectory: outer, isDirectory: true)
            // Re-parent `cyc` under its own descendant. NTFS has no such
            // check on disk, which is exactly why the walker needs one.
            try await volume.rename(at: outer, toName: "cyc", inDirectory: inner)
            try await volume.endWriteSession()
        }

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        let entries = try await volume.enumerate(directory: outer)
        XCTAssertTrue(entries.contains { $0.name == "inner" }, "cycle fixture setup failed: \(entries.map(\.name))")

        let out = try await collect(volume, from: outer, rootPath: "/cyc")
        XCTAssertEqual(out.paths, ["/cyc/inner", "/cyc/inner/cyc"],
                       "the walk must terminate at the back-edge")
        XCTAssertEqual(out.revisited, ["/cyc/inner/cyc"])
    }

    /// A REAL unreadable subdirectory: `/broken`'s MFT record has its
    /// directory flag cleared on disk, so `enumerate` throws for it while its
    /// `$I30` entry in the root still says "directory". Siblings must survive.
    func testOnDiskUnreadableSubdirectoryIsContained() async throws {
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        var brokenRecord: UInt64 = 0
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)
            try await volume.beginWriteSession()
            brokenRecord = try await volume.createFile(named: "broken", inDirectory: 5, isDirectory: true)
            _ = try await volume.createFile(named: "lost.txt", inDirectory: brokenRecord)
            _ = try await volume.createFile(named: "survivor.txt", inDirectory: 5)
            try await volume.endWriteSession()
        }
        try await Self.clearDirectoryFlag(imagePath: path, recordNumber: brokenRecord)

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))
        let out = try await collect(volume)

        XCTAssertEqual(out.failures.map(\.path), ["/broken"], "\(out.failures)")
        XCTAssertTrue(out.paths.contains("/broken"))
        XCTAssertFalse(out.paths.contains("/broken/lost.txt"))
        XCTAssertTrue(out.paths.contains("/survivor.txt"), "the rest of the walk must complete")
        XCTAssertTrue(out.paths.contains("/sub/nested.txt"))
    }

    // MARK: - Helpers

    private func fixturePath(_ file: String = #filePath) throws -> String {
        let path = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/small.img")
            .path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing at \(path); run scripts/make_test_images.sh")
        }
        return path
    }

    /// Independent recursive walk, written directly against `enumerate` — the
    /// duplication here is deliberate: it is the oracle the shared walker is
    /// checked against.
    private static func oracleWalk(
        volume: Volume,
        directory: UInt64,
        prefix: String,
        maxDepth: Int?,
        depth: Int = 1,
        visited: Set<UInt64> = [5]
    ) async throws -> [String] {
        if let maxDepth, depth > maxDepth { return [] }
        var out: [String] = []
        for entry in try await volume.enumerate(directory: directory) {
            if entry.fileName.namespace == .dos || entry.name == "." || entry.name == ".." { continue }
            let path = prefix + "/" + entry.name
            out.append(path)
            guard entry.isDirectory, !visited.contains(entry.recordNumber) else { continue }
            out += try await oracleWalk(
                volume: volume,
                directory: entry.recordNumber,
                prefix: path,
                maxDepth: maxDepth,
                depth: depth + 1,
                visited: visited.union([entry.recordNumber])
            )
        }
        return out
    }

    /// Clear `FILE_RECORD_IS_DIRECTORY` (0x0002) in the MFT record header's
    /// flags field, so `Volume.enumerate` rejects the record as "not a
    /// directory" while the parent's `$I30` entry still advertises it as one.
    ///
    /// Offset 22 sits in the record header, well clear of the Update Sequence
    /// Array fixup positions (the last two bytes of each 512-byte sector), so
    /// a direct byte patch needs no USA handling.
    private static func clearDirectoryFlag(imagePath: String, recordNumber: UInt64) async throws {
        // Non-exclusive: the writer that seeded the fixture may still be
        // finalizing its flock as this runs.
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imagePath, lockExclusive: false)
        let volume = try await Volume(device: device)
        let recordSize = Int(volume.mftRecordSizeBytes)
        let recordOffset = volume.mftByteOffset + recordNumber * UInt64(recordSize)

        let record = try await device.read(offset: recordOffset, length: recordSize)
        guard record.prefix(4) == Data("FILE".utf8) else {
            throw NTFSError.corruptOnDisk(
                description: "test helper: no FILE magic at record \(recordNumber) (offset \(recordOffset))"
            )
        }
        let flagsOffset = 22
        var flags = UInt16(record[record.startIndex + flagsOffset]) |
                    (UInt16(record[record.startIndex + flagsOffset + 1]) << 8)
        XCTAssertEqual(flags & 0x0002, 0x0002, "record \(recordNumber) should start out flagged as a directory")
        flags &= ~UInt16(0x0002)
        try await device.write(
            offset: recordOffset + UInt64(flagsOffset),
            bytes: Data([UInt8(flags & 0xFF), UInt8((flags >> 8) & 0xFF)])
        )
    }

    private static func residentBytes() -> UInt64? {
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
}

// MARK: - DirectoryEntry synthesis for stubs

/// Build a `DirectoryEntry` the way `Volume.enumerate` would, including the
/// NTFS-internal `FILE_NAME_INDEX_PRESENT` (0x10000000) directory bit.
private func makeEntry(
    name: String,
    recordNumber: UInt64,
    isDirectory: Bool,
    namespace: FileName.Namespace = .win32
) -> DirectoryEntry {
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
            namespace: namespace,
            name: name
        )
    )
}
