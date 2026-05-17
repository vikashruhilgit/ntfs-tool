import XCTest
@testable import NTFSCore

/// Tests for Bitmap.allocate/free + Volume.allocateClusters round-trips.
/// Uses MutableFixture to copy small.img into tmp per test so the committed
/// fixture stays read-only.
final class BitmapAllocatorTests: XCTestCase {

    private func fixturePath(_ name: String) -> String? {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: — In-memory Bitmap mutations

    func testMarkAllocatedFlipsBits() throws {
        var bm = Bitmap(bytes: Data(repeating: 0, count: 2), clusterCount: 16)
        try bm.markAllocated(startLCN: 3, count: 4)
        // Bits 3, 4, 5, 6 set → byte 0 = 0b01111000 = 0x78
        XCTAssertEqual(bm.bytes[0], 0x78)
        XCTAssertEqual(bm.bytes[1], 0x00)
        XCTAssertEqual(bm.allocatedClusterCount, 4)
    }

    func testMarkAllocatedSpansBytes() throws {
        var bm = Bitmap(bytes: Data(repeating: 0, count: 2), clusterCount: 16)
        try bm.markAllocated(startLCN: 6, count: 4)
        // Bits 6, 7 in byte 0 → 0xC0; bits 0, 1 in byte 1 → 0x03
        XCTAssertEqual(bm.bytes[0], 0xC0)
        XCTAssertEqual(bm.bytes[1], 0x03)
    }

    func testMarkFreeIsInverseOfAllocated() throws {
        var bm = Bitmap(bytes: Data(repeating: 0xFF, count: 2), clusterCount: 16)
        try bm.markFree(startLCN: 4, count: 8)
        // Clear bits 4-11
        XCTAssertEqual(bm.bytes[0], 0x0F)  // bits 0-3 still set
        XCTAssertEqual(bm.bytes[1], 0xF0)  // bits 12-15 still set
        XCTAssertEqual(bm.freeClusterCount, 8)
    }

    func testAllocateReturnsCorrectExtent() throws {
        // Empty bitmap (all free) → allocate(5) gets clusters 0-4.
        var bm = Bitmap(bytes: Data(repeating: 0, count: 4), clusterCount: 32)
        let extent = try bm.allocate(5)
        XCTAssertEqual(extent.startLCN, 0)
        XCTAssertEqual(extent.clusterCount, 5)
        // And the bits are now flipped.
        XCTAssertEqual(bm.allocatedClusterCount, 5)
    }

    func testAllocateSkipsOccupied() throws {
        // First 4 clusters allocated; allocate(3) should return startLCN=4.
        var bm = Bitmap(bytes: Data([0x0F, 0x00]), clusterCount: 16)
        let extent = try bm.allocate(3)
        XCTAssertEqual(extent.startLCN, 4)
        XCTAssertEqual(extent.clusterCount, 3)
        // Bitmap now has bits 0-6 set → 0x7F.
        XCTAssertEqual(bm.bytes[0], 0x7F)
    }

    func testAllocateThrowsOutOfSpace() {
        // 8 clusters, all occupied. Asking for 1 → outOfSpace.
        var bm = Bitmap(bytes: Data([0xFF]), clusterCount: 8)
        XCTAssertThrowsError(try bm.allocate(1)) { error in
            guard case NTFSError.outOfSpace = error else {
                return XCTFail("expected outOfSpace, got \(error)")
            }
        }
    }

    func testAllocateZeroRejected() {
        var bm = Bitmap(bytes: Data(repeating: 0, count: 4), clusterCount: 32)
        XCTAssertThrowsError(try bm.allocate(0)) { error in
            guard case NTFSError.ioFailure = error else {
                return XCTFail("expected ioFailure, got \(error)")
            }
        }
    }

    func testFreeReleasesExtent() throws {
        var bm = Bitmap(bytes: Data(repeating: 0, count: 4), clusterCount: 32)
        let extent = try bm.allocate(5)
        XCTAssertEqual(bm.allocatedClusterCount, 5)
        try bm.free(extent)
        XCTAssertEqual(bm.allocatedClusterCount, 0)
    }

    func testFreeOnSparseExtentIsNoop() throws {
        var bm = Bitmap(bytes: Data([0x0F]), clusterCount: 8)
        let sparse = Extent(startLCN: nil, clusterCount: 4)
        try bm.free(sparse)
        XCTAssertEqual(bm.bytes[0], 0x0F)  // unchanged
    }

    // MARK: — BlockDevice write path

    func testFileHandleBlockDeviceReadOnlyThrowsOnWrite() async throws {
        guard let path = fixturePath("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        do {
            try await device.write(offset: 0, bytes: Data([0x00]))
            XCTFail("expected readOnlyDevice")
        } catch NTFSError.readOnlyDevice {
            // expected
        }
    }

    func testFileHandleBlockDeviceWriteableRoundTrip() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)

        // Write a known byte to a known offset OUTSIDE the boot sector
        // (offset 0 would invalidate the BootSector signature).
        // Pick byte 600 — well past the boot signature at 510, before MFT.
        let testOffset: UInt64 = 600
        try await device.write(offset: testOffset, bytes: Data([0xAB, 0xCD]))

        // Re-read via a fresh handle (rules out caching).
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let bytes = try await reader.read(offset: testOffset, length: 2)
        XCTAssertEqual(bytes, Data([0xAB, 0xCD]))
    }

    // MARK: — Volume.allocateClusters round-trip on a mutable fixture

    func testAllocateClustersPersistsToDisk() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        // Open writable, snapshot free count before/after allocate.
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let before = try await volume.allocationStats()

        let extent = try await volume.allocateClusters(8)
        XCTAssertEqual(extent.clusterCount, 8)

        let afterAlloc = try await volume.allocationStats()
        XCTAssertEqual(afterAlloc.freeClusters, before.freeClusters - 8)
        XCTAssertEqual(afterAlloc.allocatedClusters, before.allocatedClusters + 8)

        // Re-open the volume with a fresh BlockDevice — proves the change
        // was actually persisted to disk (not just held in memory).
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let reopened = try await reopenedVolume.allocationStats()
        XCTAssertEqual(
            reopened.freeClusters, before.freeClusters - 8,
            "persisted bitmap should show 8 fewer free clusters after reopen"
        )
    }

    func testAllocateThenFreeRoundTrip() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let before = try await volume.allocationStats()

        let extent = try await volume.allocateClusters(16)
        try await volume.freeClusters(extent)

        let after = try await volume.allocationStats()
        XCTAssertEqual(
            after.freeClusters, before.freeClusters,
            "free → allocate → free should return to baseline"
        )
        XCTAssertEqual(after.allocatedClusters, before.allocatedClusters)

        // And the bytes really hit disk on the way out too.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let reopened = try await reopenedVolume.allocationStats()
        XCTAssertEqual(reopened.freeClusters, before.freeClusters)
    }

    func testAllocateOutOfSpaceOnFullVolume() async throws {
        guard fixturePath("small.img") != nil else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Ask for far more clusters than the 4 MiB fixture could ever hold.
        do {
            _ = try await volume.allocateClusters(100_000)
            XCTFail("expected outOfSpace")
        } catch NTFSError.outOfSpace {
            // expected
        }
    }
}
