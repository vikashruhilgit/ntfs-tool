import Foundation
import XCTest
@testable import NTFSCore

// MARK: - Test-local fault-injection block device

/// A `BlockDevice` decorator that counts reads and can fail exactly one byte
/// range, modelling a bad sector under a single MFT record.
///
/// This is the route used for the "unreadable subdirectory" case. The two
/// obvious on-disk routes are dead ends: `Volume.freeMFTRecord` mutates only
/// `$MFT.$BITMAP` and clears no record flag, and `deleteFile` removes the
/// parent's `$I30` entry *before* clearing `.inUse` — neither leaves a
/// directory that is still indexed but unreadable. Hand-patching the record's
/// bytes would require redoing the Update Sequence Array fixup and is easy to
/// get silently wrong.
///
/// Faulting the read instead is exact: `MFT.record(at:)` issues exactly one
/// `device.read(offset:length:)` per record, with no cluster batching and no
/// record cache, so an offset/length-exact fault fails that record's read and
/// nothing else.
private actor FaultingBlockDevice: BlockDevice {
    private let inner: FileHandleBlockDevice
    private let fault: (offset: UInt64, length: Int)?

    private(set) var readCount = 0
    private(set) var faultCount = 0

    /// Pass every read through; only count them.
    init(wrapping inner: FileHandleBlockDevice) {
        self.inner = inner
        self.fault = nil
    }

    /// Throw `NTFSError.ioFailure` for the read of exactly `offset`/`length`.
    init(wrapping inner: FileHandleBlockDevice, faultingReadAt offset: UInt64, length: Int) {
        self.inner = inner
        self.fault = (offset, length)
    }

    func resetCounters() {
        readCount = 0
        faultCount = 0
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        readCount += 1
        if let fault, offset == fault.offset, length == fault.length {
            faultCount += 1
            throw NTFSError.ioFailure(
                description: "simulated bad sector at offset \(offset) length \(length)"
            )
        }
        return try await inner.read(offset: offset, length: length)
    }

    func write(offset: UInt64, bytes: Data) async throws {
        try await inner.write(offset: offset, bytes: bytes)
    }

    func synchronize() async throws {
        try await inner.synchronize()
    }

    func releaseAdvisoryLock() async {
        await inner.releaseAdvisoryLock()
    }
}

// MARK: - Tests

/// Behavioural coverage for ``DirectoryWalker``: depth bounding, cycle
/// termination, per-node error containment, and the streaming (frame-stack)
/// guarantee.
///
/// Read-only depth/ordering cases run against the committed `small.img`
/// fixture (root: `hello.txt`, `medium.txt`, `sub/`; `sub/nested.txt`). The
/// deep, cyclic and faulting cases need shapes the fixture doesn't have, so
/// they build a fresh temp image with `Volume.formatNTFS` + `createFile`.
final class DirectoryWalkerTests: XCTestCase {

    // MARK: Fixture helpers

    private func fixturePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    private func smallImagePath() throws -> String {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        return path
    }

    /// Format a fresh, empty NTFS image and return its path. Cleaned up via
    /// `addTeardownBlock`. Mirrors `LargeCopyMemoryTests.makeFormattedImage`.
    private func makeFormattedImage(sizeMiB: Int = 64, label: String = "WALKER") async throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ntfscore-walker-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw NTFSError.ioFailure(description: "cannot create temp image at \(path)")
        }
        try handle.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try handle.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await device.size()
        try await Volume.formatNTFS(
            device: device, deviceSizeBytes: size,
            label: label, volumeSerial: 0x0123_4567_89AB_CDEF
        )
        // Drop the flock deterministically so the caller can re-open for
        // update without racing ARC deinit.
        await device.releaseAdvisoryLock()
        return path
    }

    /// Open a formatted temp image for update and hand the volume to `build`,
    /// then flush and release the lock so the image can be re-opened.
    private func buildImage<T>(
        sizeMiB: Int = 64,
        label: String = "WALKER",
        _ build: (Volume) async throws -> T
    ) async throws -> (path: String, result: T) {
        let path = try await makeFormattedImage(sizeMiB: sizeMiB, label: label)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let result = try await build(volume)
        try await device.synchronize()
        await device.releaseAdvisoryLock()
        return (path, result)
    }

    // MARK: Walk helpers

    /// Drain a walker, failing (rather than hanging) if it does not terminate
    /// within `limit` events. The cap is what makes the cycle test a real
    /// termination assertion instead of a suite timeout.
    private func drain(
        _ walker: inout DirectoryWalker,
        limit: Int = 4096,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [WalkEvent] {
        var events: [WalkEvent] = []
        while let event = await walker.next() {
            events.append(event)
            if events.count >= limit {
                XCTFail(
                    "walk did not terminate within \(limit) events — cycle guard regressed?",
                    file: file, line: line
                )
                break
            }
        }
        return events
    }

    private func onlyEntries(_ events: [WalkEvent]) -> [WalkEntry] {
        events.compactMap { event -> WalkEntry? in
            guard case .entry(let entry) = event else { return nil }
            return entry
        }
    }

    private func onlyErrors(_ events: [WalkEvent]) -> [WalkError] {
        events.compactMap { event -> WalkError? in
            guard case .error(let error) = event else { return nil }
            return error
        }
    }

    // MARK: - AC2: depth bounding

    /// `maxDepth: 1` must emit exactly the DOS-filtered `enumerate(directory:)`
    /// listing of the start directory — same entries, same order — and nothing
    /// below it.
    ///
    /// The oracle is `volume.enumerate(directory: 5)` filtered on
    /// `namespace != .dos`, which is an independent computation of the same
    /// set: if the walker forgot the DOS filter every 8.3-aliased entry would
    /// double, and if it descended anyway a depth-2 entry would appear.
    func testDepthOneEqualsDOSFilteredEnumerateOracle() async throws {
        let path = try smallImagePath()
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let oracle = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos }

        // Sanity: the oracle really is the fixture's root, not an empty set.
        let oracleNames = Set(oracle.map(\.name))
        XCTAssertTrue(oracleNames.contains("hello.txt"), "oracle should list hello.txt (got \(oracleNames))")
        XCTAssertTrue(oracleNames.contains("medium.txt"), "oracle should list medium.txt")
        XCTAssertTrue(oracleNames.contains("sub"), "oracle should list sub/")

        var walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 1)
        let events = await drain(&walker)
        let entries = onlyEntries(events)

        XCTAssertEqual(onlyErrors(events).count, 0, "a clean fixture must produce no error events")
        XCTAssertEqual(entries.map(\.name), oracle.map(\.name),
                       "maxDepth 1 must emit the DOS-filtered root listing in $I30 order")
        XCTAssertEqual(entries.map(\.recordNumber), oracle.map(\.recordNumber),
                       "emitted record numbers must match the oracle's")
        XCTAssertTrue(entries.allSatisfy { $0.depth == 1 },
                      "children of the walk root are depth 1; got \(Set(entries.map(\.depth)))")
        XCTAssertFalse(entries.contains { $0.path == "/sub/nested.txt" },
                       "maxDepth 1 must not emit anything below the root's children")

        // `isLastSibling` is the flag `tree` renders `└──` from: exactly one
        // entry carries it, and it is the final one.
        XCTAssertEqual(entries.filter(\.isLastSibling).count, 1)
        XCTAssertEqual(entries.last?.isLastSibling, true)
    }

    /// `maxDepth: 2` additionally emits `/sub/nested.txt` at depth 2 and stops
    /// there; the depth-1 slice is unchanged from the `maxDepth: 1` walk.
    func testDepthTwoAddsNestedEntryAndStops() async throws {
        let path = try smallImagePath()
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: path))

        let oracle = try await volume.enumerate(directory: 5)
            .filter { $0.fileName.namespace != .dos }

        var walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 2)
        let events = await drain(&walker)
        let entries = onlyEntries(events)

        XCTAssertEqual(onlyErrors(events).count, 0, "a clean fixture must produce no error events")

        let nested = try XCTUnwrap(
            entries.first { $0.path == "/sub/nested.txt" },
            "maxDepth 2 must reach sub/nested.txt (got \(entries.map(\.path)))"
        )
        XCTAssertEqual(nested.depth, 2)
        XCTAssertFalse(nested.isDirectory)

        XCTAssertEqual(entries.map(\.depth).max(), 2, "nothing deeper than maxDepth may be emitted")
        XCTAssertEqual(entries.filter { $0.depth == 1 }.map(\.name), oracle.map(\.name),
                       "the depth-1 slice must still be exactly the DOS-filtered root listing")

        // The fixture's root `.` self-entry points back at record 5, which is
        // seeded into `visited`, so it is emitted but never descended — no
        // duplicated root listing at depth 2.
        let depthTwoPaths = Set(entries.filter { $0.depth == 2 }.map(\.path))
        XCTAssertFalse(depthTwoPaths.contains("/./hello.txt"),
                       "the `.` self-entry must not be descended into")
    }

    /// `maxDepth: 0` bounds *before* enumerating: no events and, decisively,
    /// no reads at all reach the device.
    func testMaxDepthZeroEmitsNothingAndIssuesNoReads() async throws {
        let path = try smallImagePath()
        let device = FaultingBlockDevice(wrapping: try FileHandleBlockDevice(openingFileAt: path))
        let volume = try await Volume(device: device)

        // Ignore the reads `Volume.init` performs (boot sector, $MFT warm-up).
        await device.resetCounters()

        var walker = DirectoryWalker(volume: volume, root: 5, maxDepth: 0)
        let events = await drain(&walker)

        XCTAssertTrue(events.isEmpty, "maxDepth 0 must emit nothing, got \(events.count) events")
        let reads = await device.readCount
        XCTAssertEqual(reads, 0, "the depth bound must be checked before the enumerate call")
    }

    // MARK: - AC4: cycle termination

    /// A genuine on-disk `$I30` cycle (`a → b → c → a`, built with
    /// `Volume.rename`, which has no ancestor guard) must terminate, descend
    /// each directory record at most once, and emit a bounded number of events.
    ///
    /// Moving `a` under `c` detaches the cycle from the volume root, so the
    /// walk starts at `a`'s record, not at 5.
    func testDirectoryCycleTerminatesAndDescendsEachDirectoryOnce() async throws {
        let built = try await buildImage(label: "WALKCYC") { volume -> (a: UInt64, b: UInt64, c: UInt64) in
            let a = try await volume.createFile(named: "a", inDirectory: 5, isDirectory: true)
            let b = try await volume.createFile(named: "b", inDirectory: a, isDirectory: true)
            let c = try await volume.createFile(named: "c", inDirectory: b, isDirectory: true)
            _ = try await volume.createFile(named: "leaf.txt", inDirectory: c)
            // No ancestor guard in `rename`, so this really does close the loop.
            try await volume.rename(at: a, toName: "a", inDirectory: c)
            return (a, b, c)
        }
        let (a, b, c) = built.result

        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: built.path))

        // Precondition: the cycle actually exists on disk.
        let cChildren = try await volume.enumerate(directory: c)
            .filter { $0.fileName.namespace != .dos }
        XCTAssertTrue(cChildren.contains { $0.recordNumber == a },
                      "fixture precondition: /a/b/c must now index `a` (got \(cChildren.map(\.name)))")

        var walker = DirectoryWalker(volume: volume, root: a)   // unbounded depth
        let events = await drain(&walker, limit: 512)
        let entries = onlyEntries(events)

        XCTAssertEqual(onlyErrors(events).count, 0, "the cycle is well-formed; no node should fail to enumerate")
        XCTAssertLessThanOrEqual(events.count, 16,
                                 "a cycle must not inflate the event count; got \(entries.map(\.path))")

        let paths = Set(entries.map(\.path))
        XCTAssertEqual(paths, ["/b", "/b/c", "/b/c/a", "/b/c/leaf.txt"],
                       "expected each node exactly once, with the cycle edge emitted but not followed")

        // The back-edge is emitted as an entry (so `tree` can render it) but
        // must point at the start record.
        let backEdge = try XCTUnwrap(entries.first { $0.path == "/b/c/a" })
        XCTAssertEqual(backEdge.recordNumber, a)
        XCTAssertTrue(backEdge.isDirectory)

        // Each directory record was descended into at most once: `visited` is
        // seeded with the start record and gains one member per descent.
        XCTAssertEqual(walker.visited, [a, b, c],
                       "exactly the start directory plus b and c may be descended into")
        XCTAssertEqual(walker.frameDepth, 0, "every frame must be popped when the walk ends")
    }

    // MARK: - AC5: per-node error containment

    /// One unreadable directory (simulated bad sector on its MFT record) must
    /// produce exactly one `.error` event carrying that node's path, record
    /// number and depth, must not throw out of `next()`, and must not stop the
    /// siblings or an unrelated subtree from completing.
    func testUnreadableSubdirectoryIsContainedToOneErrorEvent() async throws {
        struct Layout { let parent: UInt64; let broken: UInt64; let other: UInt64; let deep: UInt64 }

        let built = try await buildImage(label: "WALKERR") { volume -> Layout in
            let parent = try await volume.createFile(named: "parent", inDirectory: 5, isDirectory: true)
            let broken = try await volume.createFile(named: "broken", inDirectory: parent, isDirectory: true)
            _ = try await volume.createFile(named: "hidden-by-fault.txt", inDirectory: broken)
            _ = try await volume.createFile(named: "sibling.txt", inDirectory: parent)
            let other = try await volume.createFile(named: "other", inDirectory: 5, isDirectory: true)
            let deep = try await volume.createFile(named: "deep", inDirectory: other, isDirectory: true)
            _ = try await volume.createFile(named: "leaf.txt", inDirectory: deep)
            return Layout(parent: parent, broken: broken, other: other, deep: deep)
        }
        let layout = built.result

        // Compute the byte range of `broken`'s MFT record. `MFT.mftRecordByteOffset`
        // is fileprivate (unreachable even under @testable), so the offset is
        // computed from the two public nonisolated properties. The contiguous
        // formula is exact here: the image was just formatted and $MFT has not
        // grown.
        let probe = try await Volume(device: try FileHandleBlockDevice(openingFileAt: built.path))
        let recordSize = Int(probe.mftRecordSizeBytes)
        let faultOffset = probe.mftByteOffset + layout.broken * UInt64(recordSize)

        let device = FaultingBlockDevice(
            wrapping: try FileHandleBlockDevice(openingFileAt: built.path),
            faultingReadAt: faultOffset,
            length: recordSize
        )
        let volume = try await Volume(device: device)

        // 1) Walk the broken directory's parent (the literal AC5 shape).
        var walker = DirectoryWalker(volume: volume, root: layout.parent)
        let events = await drain(&walker)
        let entries = onlyEntries(events)
        let errors = onlyErrors(events)

        XCTAssertEqual(errors.count, 1, "exactly one node may fail; got \(errors.map(\.path))")
        let failure = try XCTUnwrap(errors.first)
        XCTAssertEqual(failure.path, "/broken")
        XCTAssertEqual(failure.recordNumber, layout.broken)
        XCTAssertEqual(failure.depth, 1, "the failing directory's own depth, not its children's")
        let underlying = try XCTUnwrap(failure.underlying as? NTFSError)
        guard case .ioFailure(let description) = underlying else {
            return XCTFail("expected NTFSError.ioFailure, got \(underlying)")
        }
        XCTAssertTrue(description.contains("simulated bad sector"),
                      "the injected error must reach the caller intact, got: \(description)")

        // The broken directory is still emitted as an entry — only its
        // *contents* are lost.
        XCTAssertTrue(entries.contains { $0.path == "/broken" && $0.isDirectory },
                      "the unreadable directory itself must still be emitted")
        XCTAssertFalse(entries.contains { $0.path.hasPrefix("/broken/") },
                       "nothing under an unreadable directory can be emitted")

        // Containment: the sibling after it still arrives.
        XCTAssertTrue(entries.contains { $0.path == "/sibling.txt" },
                      "siblings of the failing node must still be emitted, got \(entries.map(\.path))")

        // 2) Whole-volume walk on the same faulting device: the unrelated
        //    subtree completes end to end and the failure count is unchanged.
        var rootWalker = DirectoryWalker(volume: volume, root: 5)
        let rootEvents = await drain(&rootWalker)
        let rootPaths = Set(onlyEntries(rootEvents).map(\.path))
        let rootErrors = onlyErrors(rootEvents)

        XCTAssertEqual(rootErrors.count, 1, "still exactly one failing node from the volume root")
        XCTAssertEqual(rootErrors.first?.path, "/parent/broken")
        XCTAssertEqual(rootErrors.first?.depth, 2)
        XCTAssertTrue(rootPaths.contains("/other/deep/leaf.txt"),
                      "an unrelated subtree must be walked to completion")
        XCTAssertTrue(rootPaths.contains("/parent/sibling.txt"))

        let faults = await device.faultCount
        XCTAssertGreaterThanOrEqual(faults, 1, "the fault must actually have been hit")
    }

    // MARK: - AC6: streaming / frame-stack depth

    /// After exactly one `next()` the frame stack holds exactly one frame.
    ///
    /// This is the discriminating assertion: a buffer-then-serve implementation
    /// would already have descended to the tree's full depth before handing
    /// back its first event.
    func testFirstNextOpensExactlyOneFrame() async throws {
        let built = try await buildImage(label: "WALKDEEP") { volume in
            let l1 = try await volume.createFile(named: "l1", inDirectory: 5, isDirectory: true)
            let l2 = try await volume.createFile(named: "l2", inDirectory: l1, isDirectory: true)
            let l3 = try await volume.createFile(named: "l3", inDirectory: l2, isDirectory: true)
            _ = try await volume.createFile(named: "leaf.txt", inDirectory: l3)
        }
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: built.path))

        var walker = DirectoryWalker(volume: volume, root: 5)
        XCTAssertEqual(walker.frameDepth, 0, "no frame may be opened before the first next()")

        let first = await walker.next()
        XCTAssertNotNil(first, "the fixture root is non-empty")
        XCTAssertEqual(walker.frameDepth, 1,
                       "one next() must open exactly one frame — a buffered producer would be at full depth")
    }

    /// Across a full walk the frame stack never exceeds `maxDepth`, while every
    /// in-bounds entry still streams through.
    func testFrameDepthNeverExceedsMaxDepthAcrossFullWalk() async throws {
        let built = try await buildImage(label: "WALKDEEP") { volume in
            let l1 = try await volume.createFile(named: "l1", inDirectory: 5, isDirectory: true)
            let l2 = try await volume.createFile(named: "l2", inDirectory: l1, isDirectory: true)
            let l3 = try await volume.createFile(named: "l3", inDirectory: l2, isDirectory: true)
            _ = try await volume.createFile(named: "leaf.txt", inDirectory: l3)
        }
        let volume = try await Volume(device: try FileHandleBlockDevice(openingFileAt: built.path))

        for maxDepth in 1...4 {
            var walker = DirectoryWalker(volume: volume, root: 5, maxDepth: maxDepth)
            var entries: [WalkEntry] = []
            var observedFrameHighWater = 0
            var guardCounter = 0

            while let event = await walker.next() {
                observedFrameHighWater = max(observedFrameHighWater, walker.frameDepth)
                XCTAssertLessThanOrEqual(
                    walker.frameDepth, maxDepth,
                    "frame stack grew to \(walker.frameDepth) with maxDepth \(maxDepth)"
                )
                if case .entry(let entry) = event { entries.append(entry) }
                guardCounter += 1
                if guardCounter >= 4096 {
                    XCTFail("walk did not terminate")
                    break
                }
            }

            XCTAssertEqual(walker.frameDepth, 0, "all frames must be popped at the end of the walk")
            XCTAssertLessThanOrEqual(entries.map(\.depth).max() ?? 0, maxDepth)
            XCTAssertEqual(observedFrameHighWater, maxDepth,
                           "the walk should actually reach maxDepth on a \(maxDepth)+-level fixture")
        }

        // And the deepest entry does stream through when depth allows it.
        var deepWalker = DirectoryWalker(volume: volume, root: 5, maxDepth: 4)
        let deepEvents = await drain(&deepWalker)
        let deepPaths = Set(onlyEntries(deepEvents).map(\.path))
        XCTAssertTrue(deepPaths.contains("/l1/l2/l3/leaf.txt"),
                      "every entry within the depth bound must be emitted, got \(deepPaths.sorted())")
    }

    // MARK: - DOS-alias filtering

    private func entry(record: UInt64, name: String, _ ns: FileName.Namespace) -> DirectoryEntry {
        DirectoryEntry(
            fileReference: record,
            recordNumber: record,
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
                fileAttributes: 0,
                namespace: ns,
                name: name
            )
        )
    }

    /// A record carrying both a Win32 name and its 8.3 alias must collapse to
    /// the long name — the de-duplication the filter exists for.
    func testDOSAliasIsDroppedWhenRecordAlsoHasALongName() {
        let kept = DirectoryWalker.dropRedundantDOSAliases([
            entry(record: 64, name: "LongFileName.txt", .win32),
            entry(record: 64, name: "LONGFI~1.TXT", .dos),
        ])
        XCTAssertEqual(kept.map(\.name), ["LongFileName.txt"])
    }

    /// The regression this fix exists for: a record whose *only* `$FILE_NAME`
    /// is an 8.3 alias must still be emitted. A blanket `namespace != .dos`
    /// filter silently drops such a file from `tree`/`find`/`list`, which
    /// callers read as a complete listing.
    func testDOSOnlyRecordSurvivesFiltering() {
        let kept = DirectoryWalker.dropRedundantDOSAliases([
            entry(record: 64, name: "NORMAL.TXT", .win32),
            entry(record: 65, name: "ORPHAN~1.TXT", .dos),
        ])
        XCTAssertEqual(kept.map(\.name).sorted(), ["NORMAL.TXT", "ORPHAN~1.TXT"],
                       "a record with no long name must not vanish from the walk")
    }

    /// `win32AndDos` (namespace 3) is a single entry serving both roles and
    /// must never be filtered.
    func testWin32AndDOSEntryIsNeverFiltered() {
        let kept = DirectoryWalker.dropRedundantDOSAliases([
            entry(record: 64, name: "SHORT.TXT", .win32AndDos),
        ])
        XCTAssertEqual(kept.map(\.name), ["SHORT.TXT"])
    }
}
