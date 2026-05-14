import XCTest
@testable import NTFSCore

final class BootSectorTests: XCTestCase {

    /// Build a synthetic 512-byte NTFS boot sector with known field values so the
    /// parser can be tested without an external `.img` fixture (Phase 1 — real
    /// fixtures land in Phase 1.5 once `scripts/make_test_images.sh` is wired up).
    private static func sampleBootSector() -> Data {
        var data = Data(repeating: 0, count: BootSector.onDiskSize)

        // Offset 0-2: jump instruction (typical NTFS value 0xEB 0x52 0x90)
        data[0] = 0xEB; data[1] = 0x52; data[2] = 0x90

        // Offset 3-10: OEM ID "NTFS    " (NTFS followed by four spaces)
        for (i, byte) in "NTFS    ".utf8.enumerated() {
            data[3 + i] = byte
        }

        // Offset 11-12: bytes per sector = 512 (little-endian)
        data[11] = 0x00; data[12] = 0x02

        // Offset 13: sectors per cluster = 8
        data[13] = 0x08

        // Offset 21: media descriptor = 0xF8 (fixed disk)
        data[21] = 0xF8

        // Offset 40-47: total sectors = 2,097,152 (a 1 GiB volume at 512-byte sectors)
        // 0x0000_0000_0020_0000
        write(&data, at: 40, value: UInt64(2_097_152))

        // Offset 48-55: MFT cluster = 786,432 (typical mid-volume placement)
        write(&data, at: 48, value: UInt64(786_432))

        // Offset 56-63: MFT mirror cluster = 1,048,576
        write(&data, at: 56, value: UInt64(1_048_576))

        // Offset 64: clusters per MFT record = -10 → 2^10 = 1024 bytes per record
        data[64] = UInt8(bitPattern: -10)

        // Offset 68: clusters per index record = 1 → 1 cluster (4096 bytes here)
        data[68] = 0x01

        // Offset 72-79: volume serial = 0x123456789ABCDEF0
        write(&data, at: 72, value: UInt64(0x1234_5678_9ABC_DEF0))

        // Offset 510-511: boot sector signature 0xAA55 (little-endian: 0x55 0xAA)
        data[510] = 0x55; data[511] = 0xAA

        return data
    }

    private static func write(_ data: inout Data, at offset: Int, value: UInt64) {
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
        }
    }

    func testParseValidBootSector() throws {
        let bs = try BootSector.parse(Self.sampleBootSector())
        XCTAssertEqual(bs.oemID, "NTFS    ")
        XCTAssertEqual(bs.bytesPerSector, 512)
        XCTAssertEqual(bs.sectorsPerCluster, 8)
        XCTAssertEqual(bs.mediaDescriptor, 0xF8)
        XCTAssertEqual(bs.totalSectors, 2_097_152)
        XCTAssertEqual(bs.mftCluster, 786_432)
        XCTAssertEqual(bs.mftMirrorCluster, 1_048_576)
        XCTAssertEqual(bs.clustersPerMFTRecord, -10)
        XCTAssertEqual(bs.clustersPerIndexRecord, 1)
        XCTAssertEqual(bs.volumeSerial, 0x1234_5678_9ABC_DEF0)
        XCTAssertEqual(bs.bootSectorSignature, 0xAA55)
    }

    func testRejectsWrongOEMID() {
        var data = Self.sampleBootSector()
        data[3] = 0x4D; data[4] = 0x53  // "MS" instead of "NT"
        XCTAssertThrowsError(try BootSector.parse(data)) { error in
            guard case NTFSError.invalidBootSector = error else {
                return XCTFail("expected invalidBootSector, got \(error)")
            }
        }
    }

    func testRejectsInvalidSignature() {
        var data = Self.sampleBootSector()
        data[510] = 0x00; data[511] = 0x00
        XCTAssertThrowsError(try BootSector.parse(data)) { error in
            guard case NTFSError.invalidBootSector = error else {
                return XCTFail("expected invalidBootSector, got \(error)")
            }
        }
    }

    func testRejectsBadBytesPerSector() {
        var data = Self.sampleBootSector()
        data[11] = 0x07; data[12] = 0x00  // 7 — not a valid sector size
        XCTAssertThrowsError(try BootSector.parse(data)) { error in
            guard case NTFSError.invalidBootSector = error else {
                return XCTFail("expected invalidBootSector, got \(error)")
            }
        }
    }

    func testRejectsNonPowerOfTwoSectorsPerCluster() {
        var data = Self.sampleBootSector()
        data[13] = 3  // not a power of two
        XCTAssertThrowsError(try BootSector.parse(data)) { error in
            guard case NTFSError.invalidBootSector = error else {
                return XCTFail("expected invalidBootSector, got \(error)")
            }
        }
    }

    func testRejectsWrongLength() {
        let short = Data(repeating: 0, count: 256)
        XCTAssertThrowsError(try BootSector.parse(short)) { error in
            guard case NTFSError.invalidBootSector = error else {
                return XCTFail("expected invalidBootSector, got \(error)")
            }
        }
    }

    func testResolveRecordSizePositive() {
        // 2 clusters * 4096 bytes/cluster = 8192
        XCTAssertEqual(BootSector.resolveRecordSize(field: 2, clusterSizeBytes: 4096), 8192)
    }

    func testResolveRecordSizeNegative() {
        // -10 → 2^10 = 1024 bytes (cluster size irrelevant)
        XCTAssertEqual(BootSector.resolveRecordSize(field: -10, clusterSizeBytes: 4096), 1024)
    }
}
