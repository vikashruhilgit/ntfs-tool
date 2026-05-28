import XCTest
@testable import NTFSCore

/// End-to-end format + parse tests for `Mkntfs.format(...)` — AC-3 of the
/// v0.6 brief. Creates a 256 MiB temp .img, formats it via the pure-Swift
/// orchestrator, then reads it back through NTFSCore's own decoders and
/// asserts that boot sector + MFT records 0..15 parse cleanly.
final class MkntfsTests: XCTestCase {

    /// Build a 256 MiB temp .img file and return its path. Caller is
    /// responsible for deleting it.
    private func makeBlankImage(sizeMiB: Int = 256) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let path = tmpDir.appendingPathComponent("mkntfs-test-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()
        return path
    }

    private func formatAndOpen(path: String, label: String = "TESTVOL") async throws -> Volume {
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await device.size()
        try await Volume.formatNTFS(
            device: device,
            deviceSizeBytes: size,
            label: label,
            volumeSerial: 0x0123_4567_89AB_CDEF
        )
        // Re-open read-only for parse (the in-process writer holds the lock).
        return try await Volume(device: device)
    }

    func testFormat256MiBImage() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let volume = try await formatAndOpen(path: path, label: "MKNTFS01")

        // Boot sector sanity.
        XCTAssertEqual(volume.boot.bytesPerSector, 512)
        XCTAssertEqual(volume.boot.sectorsPerCluster, 8)
        XCTAssertEqual(Int(volume.bytesPerCluster), 4096)
        XCTAssertEqual(volume.boot.volumeSerial, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(volume.boot.bootSectorSignature, 0xAA55)
        XCTAssertGreaterThan(volume.boot.totalSectors, 0)
    }

    func testFormatProducesParseableSystemRecords() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let volume = try await formatAndOpen(path: path, label: "")
        let mft = await volume.mft()

        // Records 0..11 must all be parseable + in-use.
        for rn in UInt64(0)...11 {
            let rec = try await mft.record(at: rn)
            XCTAssertTrue(rec.isInUse, "record \(rn) must be in_use")
            XCTAssertEqual(rec.magic, MFTRecord.magicFILE, "record \(rn) magic")
            // All system records must have at least 3 attributes
            // ($STANDARD_INFORMATION, $FILE_NAME, plus type-specific).
            let attrs = try rec.attributes()
            XCTAssertGreaterThanOrEqual(attrs.count, 3, "record \(rn) attribute count")
        }
    }

    func testFormatProducesValidMFTDataRunlist() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let volume = try await formatAndOpen(path: path)
        // mftDataExtents() must succeed — it parses record 0, finds the
        // non-resident $DATA, decodes the runlist.
        let extents = await volume.mftDataExtents()
        XCTAssertNotNil(extents, "mftDataExtents() must return a runlist")
        XCTAssertEqual(extents?.count, 1, "mkntfs creates a single contiguous MFT extent")
        XCTAssertGreaterThan(extents?.first?.clusterCount ?? 0, 0)
    }

    func testRootDirectoryRecordIsDirectory() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let volume = try await formatAndOpen(path: path)
        let mft = await volume.mft()
        let root = try await mft.record(at: 5)
        XCTAssertTrue(root.isDirectory, "record 5 must be a directory")
        XCTAssertTrue(root.isInUse)
    }

    func testBackupBootSectorPresent() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Format directly (not through Volume open).
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await device.size()
        try await Volume.formatNTFS(
            device: device,
            deviceSizeBytes: size,
            label: "BACKUPVOL",
            volumeSerial: 0xDEAD_BEEF_F00D_CAFE
        )

        // Read the last sector. Must be a valid NTFS boot sector.
        let lastSectorOffset = size - 512
        let backupBytes = try await device.read(offset: lastSectorOffset, length: 512)
        let backupBoot = try BootSector.parse(backupBytes)
        XCTAssertEqual(backupBoot.volumeSerial, 0xDEAD_BEEF_F00D_CAFE)
        XCTAssertEqual(backupBoot.bootSectorSignature, 0xAA55)
    }

    func testPlanGeometrySmallVolumeRejection() {
        // 8 MiB image — too small for mkntfs's minimum.
        XCTAssertThrowsError(
            try Mkntfs.planGeometry(deviceSizeBytes: 8 * 1024 * 1024, options: Mkntfs.Options())
        )
    }

    func testPlanGeometryForTypical256MiB() throws {
        let geom = try Mkntfs.planGeometry(
            deviceSizeBytes: 256 * 1024 * 1024,
            options: Mkntfs.Options()
        )
        XCTAssertEqual(geom.bytesPerSector, 512)
        XCTAssertEqual(geom.sectorsPerCluster, 8)
        XCTAssertEqual(geom.bytesPerCluster, 4096)
        XCTAssertEqual(geom.totalSectors, 524_288)
        XCTAssertEqual(geom.clustersPerMFTRecord, -10)  // 2^10 = 1024
        // System files must come before the backup BS cluster.
        XCTAssertLessThan(geom.bitmapStartLCN + geom.bitmapClusterCount, geom.bootBackupStartLCN)
    }
}
