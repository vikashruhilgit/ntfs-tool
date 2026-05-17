import XCTest
@testable import NTFSCore

final class MFTTests: XCTestCase {

    private func fixturePath(_ name: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    // MARK: — Hand-crafted MFT record (no fixture required)

    /// Build a synthetic 1024-byte MFT record with USA = [0xCAFE, 0xDEAD, 0xBEEF].
    /// Sentinels (0xCAFE) are placed at offsets 510 and 1022 (last 2 bytes of each
    /// 512-byte block); the "real" bytes at those positions are 0xDEAD and 0xBEEF
    /// respectively, stored in USA[1] and USA[2]. After fix-up, offsets 510-511
    /// should read 0xDEAD and offsets 1022-1023 should read 0xBEEF.
    private static func sampleMFTRecord(
        inUse: Bool = true,
        directory: Bool = false,
        sequenceNumber: UInt16 = 1,
        sentinel: UInt16 = 0xCAFE,
        magic: UInt32 = MFTRecord.magicFILE
    ) -> Data {
        var data = Data(repeating: 0, count: 1024)

        func writeU16(at offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        }
        func writeU32(at offset: Int, _ value: UInt32) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        func writeU64(at offset: Int, _ value: UInt64) {
            for i in 0..<8 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }

        // Magic
        writeU32(at: 0, magic)
        // USA offset = 48 (just past the standard NTFS 3.1 header)
        writeU16(at: 4, 48)
        // USA count = 1 sentinel + 2 fix-ups = 3
        writeU16(at: 6, 3)
        // $LogFile sequence number
        writeU64(at: 8, 0xAAAA_BBBB_CCCC_DDDD)
        // Sequence number
        writeU16(at: 16, sequenceNumber)
        // Hard link count
        writeU16(at: 18, 1)
        // First attribute offset (immediately after the USA: 48 + 6 = 54, rounded up to 56)
        writeU16(at: 20, 56)
        // Flags
        var flags: UInt16 = 0
        if inUse      { flags |= 0x0001 }
        if directory  { flags |= 0x0002 }
        writeU16(at: 22, flags)
        // Used size
        writeU32(at: 24, 256)
        // Allocated size
        writeU32(at: 28, 1024)
        // Base file reference (0 = base record)
        writeU64(at: 32, 0)
        // Next attribute ID
        writeU16(at: 40, 5)
        // MFT record number (NTFS 3.1+ field at offset 44)
        writeU32(at: 44, 42)

        // USA: sentinel + 2 fix-ups
        writeU16(at: 48, sentinel)       // USA[0] sentinel
        writeU16(at: 50, 0xDEAD)         // USA[1] — original bytes for block 0 tail
        writeU16(at: 52, 0xBEEF)         // USA[2] — original bytes for block 1 tail

        // Place sentinels at the last 2 bytes of each 512-byte block
        writeU16(at: 510, sentinel)
        writeU16(at: 1022, sentinel)

        return data
    }

    func testParseValidMFTRecord() throws {
        let raw = Self.sampleMFTRecord()
        let record = try MFTRecord.parse(raw, expectedSize: 1024)

        XCTAssertEqual(record.magic, MFTRecord.magicFILE)
        XCTAssertEqual(record.usaOffset, 48)
        XCTAssertEqual(record.usaCount, 3)
        XCTAssertEqual(record.logFileSequenceNumber, 0xAAAA_BBBB_CCCC_DDDD)
        XCTAssertEqual(record.sequenceNumber, 1)
        XCTAssertEqual(record.hardLinkCount, 1)
        XCTAssertEqual(record.firstAttributeOffset, 56)
        XCTAssertTrue(record.flags.contains(.inUse))
        XCTAssertFalse(record.flags.contains(.directory))
        XCTAssertEqual(record.usedSize, 256)
        XCTAssertEqual(record.allocatedSize, 1024)
        XCTAssertEqual(record.baseFileReference, 0)
        XCTAssertEqual(record.nextAttributeID, 5)
        XCTAssertEqual(record.mftRecordNumber, 42)
        XCTAssertTrue(record.isInUse)
        XCTAssertFalse(record.isDirectory)
        XCTAssertTrue(record.isBaseRecord)
    }

    func testUSAFixupRestoresOriginalBytes() throws {
        let raw = Self.sampleMFTRecord()
        let record = try MFTRecord.parse(raw, expectedSize: 1024)

        // After fix-up: the sentinels at block tails are replaced by the bytes
        // that were saved in USA[1..N]. We wrote USA[1] = 0xDEAD (block 0 tail)
        // and USA[2] = 0xBEEF (block 1 tail).
        let block0Tail = try record.bytes.readU16LE(at: 510)
        let block1Tail = try record.bytes.readU16LE(at: 1022)
        XCTAssertEqual(block0Tail, 0xDEAD, "block 0 tail should be restored to USA[1]")
        XCTAssertEqual(block1Tail, 0xBEEF, "block 1 tail should be restored to USA[2]")
    }

    func testUSAMismatchRejected() throws {
        var raw = Self.sampleMFTRecord()
        // Corrupt the sentinel in block 1 — simulate a torn write.
        raw[1022] = 0x00
        raw[1023] = 0x00

        XCTAssertThrowsError(try MFTRecord.parse(raw, expectedSize: 1024)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testRejectsWrongMagic() throws {
        var raw = Self.sampleMFTRecord(magic: MFTRecord.magicFILE)
        // Replace 'FILE' with 'XXXX' so we don't accidentally hit the BAAD branch
        raw[0] = 0x58; raw[1] = 0x58; raw[2] = 0x58; raw[3] = 0x58
        XCTAssertThrowsError(try MFTRecord.parse(raw, expectedSize: 1024)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testRejectsBAADRecord() throws {
        let raw = Self.sampleMFTRecord(magic: MFTRecord.magicBAAD)
        XCTAssertThrowsError(try MFTRecord.parse(raw, expectedSize: 1024)) { error in
            guard case let NTFSError.corruptOnDisk(reason) = error,
                  reason.contains("BAAD") else {
                return XCTFail("expected corruptOnDisk with BAAD reason, got \(error)")
            }
        }
    }

    func testFreeRecordHasNoInUseFlag() throws {
        let raw = Self.sampleMFTRecord(inUse: false)
        let record = try MFTRecord.parse(raw, expectedSize: 1024)
        XCTAssertFalse(record.isInUse)
        XCTAssertTrue(record.isBaseRecord)
    }

    func testRejectsSizeMismatch() throws {
        let raw = Self.sampleMFTRecord()
        XCTAssertThrowsError(try MFTRecord.parse(raw, expectedSize: 2048)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    // MARK: — Live fixture (small.img) tests

    func testReadMFTSelfRecordFromFixture() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Record 0 is $MFT itself — its very own description sits at the start
        // of the table.
        let record0 = try await mft.record(at: 0)
        XCTAssertEqual(record0.magic, MFTRecord.magicFILE)
        XCTAssertTrue(record0.isInUse, "$MFT (record 0) should be in use on a freshly-formatted volume")
        XCTAssertTrue(record0.isBaseRecord, "$MFT should be a base record (baseFileReference == 0)")
        XCTAssertGreaterThan(record0.firstAttributeOffset, 0)
        XCTAssertLessThan(Int(record0.firstAttributeOffset), Int(record0.allocatedSize))
        XCTAssertEqual(record0.allocatedSize, volume.mftRecordSizeBytes)
    }

    func testReadRootDirectoryRecordFromFixture() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Record 5 is "." — the volume root directory.
        let record5 = try await mft.record(at: 5)
        XCTAssertEqual(record5.magic, MFTRecord.magicFILE)
        XCTAssertTrue(record5.isInUse, "root directory record should be in use")
        XCTAssertTrue(record5.isDirectory, "root directory record should have DIRECTORY flag set")
        XCTAssertTrue(record5.isBaseRecord)
    }

    func testReadMultipleMFTRecordsFromFixture() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Records 0..15 are reserved NTFS metadata files. They all start with FILE
        // and have the in-use flag set on a fresh volume.
        for recordNumber in UInt64(0)...UInt64(11) {
            let record = try await mft.record(at: recordNumber)
            XCTAssertEqual(
                record.magic, MFTRecord.magicFILE,
                "MFT record \(recordNumber) should have FILE magic"
            )
            XCTAssertTrue(
                record.isInUse,
                "MFT record \(recordNumber) should be in use on a fresh volume"
            )
        }
    }
}
