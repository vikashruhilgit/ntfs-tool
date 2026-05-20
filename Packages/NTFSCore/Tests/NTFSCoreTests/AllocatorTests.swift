import XCTest
@testable import NTFSCore

/// Tests for the v0.5 next-fit cluster allocator: a rolling per-Volume search
/// hint (`_allocHint`) plus wrap-around `Bitmap.findFreeRun`. Together they
/// keep sequential `cp -r` writes contiguous (single-extent runlists) instead
/// of refilling scattered holes near cluster 0 — the fragmentation that
/// overflowed a thumbnail's base MFT record at file ~350 on real hardware.
final class AllocatorTests: XCTestCase {

    private func fixturePath(_ name: String) -> String? {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: — AC-3: sequential writes produce contiguous, single-extent runs

    /// On a contiguous-free region, a sequence of single-cluster allocations
    /// must yield consecutive, monotonically increasing, non-overlapping
    /// single-cluster extents — proof the rolling hint keeps sequential writes
    /// contiguous rather than scattering them across the volume. Driven on a
    /// synthetic all-free Bitmap so the result is deterministic regardless of
    /// the committed fixture's metadata layout; mirrors exactly what
    /// `Volume.allocateClusters` does (allocate at hint, advance hint).
    func testNextFitAllocatorProducesContiguousRuns() throws {
        var bm = Bitmap(bytes: Data(repeating: 0, count: 8), clusterCount: 64)
        var hint: UInt64 = 0

        let n = 16
        var extents: [Extent] = []
        for _ in 0..<n {
            let e = try bm.allocate(1, startingAt: hint)
            XCTAssertEqual(e.clusterCount, 1, "each allocation is one cluster")
            hint = (try XCTUnwrap(e.startLCN) + e.clusterCount) % bm.clusterCount
            extents.append(e)
        }

        // First allocation lands at cluster 0, each subsequent one is +1.
        XCTAssertEqual(extents.first?.startLCN, 0)
        for i in 1..<extents.count {
            let prev = try XCTUnwrap(extents[i - 1].startLCN)
            let cur = try XCTUnwrap(extents[i].startLCN)
            XCTAssertEqual(
                cur, prev + 1,
                "sequential single-cluster allocations must be contiguous & ascending; got \(prev) then \(cur)"
            )
        }

        // No overlaps: the set of allocated LCNs has exactly n distinct values.
        let lcns = try extents.map { try XCTUnwrap($0.startLCN) }
        XCTAssertEqual(Set(lcns).count, n, "no two extents may overlap")
    }

    /// End-to-end on the real fixture: even though `small.img`'s low clusters
    /// are fragmented by metadata, single-cluster allocations must still be
    /// strictly ascending and non-overlapping (the next-fit hint never hands
    /// out a cluster below where it last allocated until it wraps), and once
    /// the allocator reaches the contiguous free tail the runs ARE contiguous.
    func testVolumeSequentialAllocationsAscendAndDoNotOverlap() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let n = 32
        var lcns: [UInt64] = []
        for _ in 0..<n {
            let e = try await volume.allocateClusters(1)
            XCTAssertEqual(e.clusterCount, 1)
            lcns.append(try XCTUnwrap(e.startLCN))
        }

        // Strictly ascending (no wrap expected — the fixture has ample free
        // space above the fragmented metadata zone).
        for i in 1..<lcns.count {
            XCTAssertGreaterThan(
                lcns[i], lcns[i - 1],
                "next-fit allocations ascend; got \(lcns[i - 1]) then \(lcns[i])"
            )
        }
        XCTAssertEqual(Set(lcns).count, n, "no two extents overlap")

        // The tail of the run lands in the contiguous free zone, so the last
        // several allocations must be perfectly contiguous (+1 each).
        let tail = Array(lcns.suffix(8))
        for i in 1..<tail.count {
            XCTAssertEqual(
                tail[i], tail[i - 1] + 1,
                "allocations in the contiguous free tail must be +1 apart; got \(tail[i - 1]) then \(tail[i])"
            )
        }
    }

    // MARK: — AC-1 / AC-4: wrap-around uses ALL free space, strands nothing

    /// A holed bitmap with a high `startingAt` must still find free runs that
    /// lie BELOW the hint via wrap-around (pass 2). Without wrap-around the
    /// low free clusters would be unreachable once the hint advances past them.
    func testWrapAroundFindFreeRunUsesAllFreeSpace() throws {
        // 16 clusters. Free: 1,2 (low) and 9,10,11 (high). Rest allocated.
        // byte0 = clusters 0..7, byte1 = clusters 8..15.
        // Allocated low: 0,3,4,5,6,7 → byte0 = 0b11111001 = 0xF9 (free 1,2).
        // Allocated high: 8,12,13,14,15 → byte1 = 0b11110001 = 0xF1 (free 9,10,11).
        let bm = Bitmap(bytes: Data([0xF9, 0xF1]), clusterCount: 16)

        // Hint past the high free run: pass 1 [13,16) finds nothing free,
        // pass 2 [0,13) must find the low run at cluster 1.
        XCTAssertEqual(
            bm.findFreeRun(count: 2, startingAt: 13), 1,
            "wrap-around must reach the low free run below the hint"
        )

        // A stale hint >= clusterCount must clamp to a full scan (find cluster 1).
        XCTAssertEqual(
            bm.findFreeRun(count: 1, startingAt: 999), 1,
            "stale hint past clusterCount clamps to a full scan from 0"
        )

        // A run must NOT span the wrap boundary: clusters 9,10,11 are free but
        // 8 and 12 are not, and 15 is not free, so no 4-run exists that would
        // wrap from the top into the low free clusters.
        XCTAssertNil(
            bm.findFreeRun(count: 4, startingAt: 9),
            "a free run must never span the wrap boundary"
        )
        // The high run of exactly 3 is reachable from a high hint (pass 1).
        XCTAssertEqual(bm.findFreeRun(count: 3, startingAt: 9), 9)
    }

    /// Drive repeated `Bitmap.allocate` with an advancing hint against a
    /// fragmented bitmap and assert it allocates down to the LAST free cluster
    /// and only throws `outOfSpace` when genuinely full — no free space is
    /// stranded below the hint.
    func testRepeatedAllocateWithAdvancingHintDrainsAllFreeSpace() throws {
        // 16 clusters, 5 free: 1,2 (low) and 9,10,11 (high). 11 allocated.
        var bm = Bitmap(bytes: Data([0xF9, 0xF1]), clusterCount: 16)
        XCTAssertEqual(bm.freeClusterCount, 5)

        // Start the hint high (past the high free run) so we exercise wrap.
        var hint: UInt64 = 12
        var allocated: [UInt64] = []
        for _ in 0..<5 {
            let e = try bm.allocate(1, startingAt: hint)
            let lcn = try XCTUnwrap(e.startLCN)
            allocated.append(lcn)
            hint = (lcn + e.clusterCount) % bm.clusterCount
        }

        XCTAssertEqual(
            Set(allocated), Set([1, 2, 9, 10, 11]),
            "all 5 free clusters must be handed out exactly once — none stranded"
        )
        XCTAssertEqual(bm.freeClusterCount, 0, "bitmap should now be full")

        // Genuinely full → outOfSpace, regardless of hint.
        XCTAssertThrowsError(try bm.allocate(1, startingAt: hint)) { error in
            guard case NTFSError.outOfSpace = error else {
                return XCTFail("expected outOfSpace, got \(error)")
            }
        }
    }

    /// `Volume.allocateClustersFragmented` against a (real) fixture should
    /// exhaust the volume's free space without stranding any: requesting more
    /// than free count throws outOfSpace, but requesting exactly the free
    /// count succeeds and leaves zero free.
    func testFragmentedAllocationLeavesNoStrandedSpace() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let before = try await volume.allocationStats()
        let free = before.freeClusters
        XCTAssertGreaterThan(free, 0)

        let extents = try await volume.allocateClustersFragmented(count: free)
        let total = extents.reduce(UInt64(0)) { $0 + $1.clusterCount }
        XCTAssertEqual(total, free, "fragmented allocation must satisfy the full request")

        let after = try await volume.allocationStats()
        XCTAssertEqual(after.freeClusters, 0, "no free clusters may be stranded")
    }

    // MARK: — AC-7: the hint advances across allocations and wraps at end

    func testAllocHintAdvancesAcrossAllocations() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let hint0 = await volume._currentAllocHintForTesting()
        XCTAssertEqual(hint0, 0, "hint starts at 0 on a fresh Volume")

        let e1 = try await volume.allocateClusters(4)
        let start1 = try XCTUnwrap(e1.startLCN)
        let hint1 = await volume._currentAllocHintForTesting()
        XCTAssertEqual(
            hint1, start1 + 4,
            "hint advances to the cluster after the last allocated one"
        )

        let e2 = try await volume.allocateClusters(2)
        let start2 = try XCTUnwrap(e2.startLCN)
        let hint2 = await volume._currentAllocHintForTesting()
        XCTAssertEqual(hint2, start2 + 2)
        XCTAssertGreaterThanOrEqual(
            start2, start1 + 4,
            "the second allocation continues from where the first ended"
        )
    }

    /// The hint wraps to a low cluster modulo clusterCount when an allocation
    /// ends exactly at end-of-volume. Asserted at the Bitmap level where we
    /// can construct an end-of-volume allocation deterministically.
    func testAllocHintWrapsAtEndOfVolume() throws {
        // 8 clusters, all free.
        var bm = Bitmap(bytes: Data([0x00]), clusterCount: 8)

        // Allocate the last 3 clusters (5,6,7) via a high hint.
        let e = try bm.allocate(3, startingAt: 5)
        XCTAssertEqual(e.startLCN, 5)
        // Simulate Volume's advance: (5 + 3) % 8 == 0 → wraps to cluster 0.
        let nextHint = (try XCTUnwrap(e.startLCN) + e.clusterCount) % bm.clusterCount
        XCTAssertEqual(nextHint, 0, "hint must wrap to 0 after allocating up to end-of-volume")

        // And the next allocation from the wrapped hint lands at cluster 0.
        let e2 = try bm.allocate(2, startingAt: nextHint)
        XCTAssertEqual(e2.startLCN, 0, "wrapped hint allocates from the low end")
    }
}
