import XCTest
@testable import NTFSCore

final class BitmapTests: XCTestCase {

    private func fixturePath(_ name: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    func testIsAllocatedHappyPath() {
        // Bitmap: byte 0 = 0b10100101 (clusters 0, 2, 5, 7 allocated; rest free).
        let bm = Bitmap(bytes: Data([0b10100101]), clusterCount: 8)
        XCTAssertTrue(bm.isAllocated(cluster: 0))
        XCTAssertFalse(bm.isAllocated(cluster: 1))
        XCTAssertTrue(bm.isAllocated(cluster: 2))
        XCTAssertFalse(bm.isAllocated(cluster: 3))
        XCTAssertFalse(bm.isAllocated(cluster: 4))
        XCTAssertTrue(bm.isAllocated(cluster: 5))
        XCTAssertFalse(bm.isAllocated(cluster: 6))
        XCTAssertTrue(bm.isAllocated(cluster: 7))
    }

    func testOutOfRangeIsAllocated() {
        // Cluster index past clusterCount → treated as allocated (defensive).
        let bm = Bitmap(bytes: Data([0]), clusterCount: 4)
        XCTAssertTrue(bm.isAllocated(cluster: 4))
        XCTAssertTrue(bm.isAllocated(cluster: 100_000))
    }

    func testFreeClusterCount() {
        // Two full bytes: 0b11111111 (8 allocated) + 0b00000000 (8 free) = 8 free.
        let bm = Bitmap(bytes: Data([0xFF, 0x00]), clusterCount: 16)
        XCTAssertEqual(bm.freeClusterCount, 8)
        XCTAssertEqual(bm.allocatedClusterCount, 8)
    }

    func testFreeCountIgnoresTailPaddingBits() {
        // Bitmap byte is 0b00000000 (all 8 bits zero) but clusterCount = 5.
        // The 3 padding bits beyond cluster 5 must NOT be counted as free.
        let bm = Bitmap(bytes: Data([0b00000000]), clusterCount: 5)
        XCTAssertEqual(bm.freeClusterCount, 5)
    }

    func testFindFreeRunSmall() {
        // 0b11000111 = clusters 0,1,2 free + 6,7 allocated; cluster 3,4,5 allocated.
        // Wait — bit 0 = LSB. Byte 0b11000111 means cluster 0 alloc, 1 alloc,
        // 2 alloc, 3 free, 4 free, 5 free, 6 alloc, 7 alloc.
        let bm = Bitmap(bytes: Data([0b11000111]), clusterCount: 8)
        XCTAssertEqual(bm.findFreeRun(count: 3), 3)
        XCTAssertEqual(bm.findFreeRun(count: 1), 3)
        XCTAssertNil(bm.findFreeRun(count: 4))   // no 4-cluster free run
    }

    func testFindFreeRunStartingAt() {
        let bm = Bitmap(bytes: Data([0b11000111]), clusterCount: 8)
        XCTAssertEqual(bm.findFreeRun(count: 2, startingAt: 4), 4)
        XCTAssertNil(bm.findFreeRun(count: 2, startingAt: 6))  // 6,7 are allocated
    }

    func testFindFreeRunSpansByteBoundary() {
        // Byte 0 = 0b11110000 (clusters 0-3 free, 4-7 alloc)
        // Byte 1 = 0b00000001 (cluster 8 alloc, 9-15 free)
        // Should find a run of 7 starting at cluster 9.
        let bm = Bitmap(bytes: Data([0b11110000, 0b00000001]), clusterCount: 16)
        XCTAssertEqual(bm.findFreeRun(count: 7), 9)
        XCTAssertEqual(bm.findFreeRun(count: 4), 0)
    }

    func testFindZeroRunReturnsStartingAt() {
        let bm = Bitmap(bytes: Data([0xFF]), clusterCount: 8)
        XCTAssertEqual(bm.findFreeRun(count: 0, startingAt: 3), 3)
    }

    // MARK: — Live fixture

    func testLiveFixtureBitmapStatsLookSane() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let stats = try await volume.allocationStats()

        // Volume is 4 MiB / 4 KiB cluster = 1024 clusters. Allow ±1 for the
        // boot sector — totalSectors is volume - 1 sector on mkntfs.
        XCTAssertTrue(
            (1022...1024).contains(stats.totalClusters),
            "expected ~1024 clusters, got \(stats.totalClusters)"
        )
        XCTAssertTrue(stats.freeClusters > 0, "free should be > 0 on a fresh 4 MiB fixture")
        XCTAssertTrue(stats.allocatedClusters > 0, "allocated should be > 0 (NTFS metadata)")
        XCTAssertEqual(stats.freeClusters + stats.allocatedClusters, stats.totalClusters)

        // Byte totals should be cluster counts × 4096.
        XCTAssertEqual(stats.totalBytes, stats.totalClusters * 4096)
        XCTAssertEqual(stats.freeBytes, stats.freeClusters * 4096)
    }

    func testBitmapCacheReturnsSameInstance() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let bm1 = try await volume.bitmap()
        let bm2 = try await volume.bitmap()
        // Same content — caching means the second call doesn't re-read.
        XCTAssertEqual(bm1.bytes, bm2.bytes)
        XCTAssertEqual(bm1.clusterCount, bm2.clusterCount)
    }
}
