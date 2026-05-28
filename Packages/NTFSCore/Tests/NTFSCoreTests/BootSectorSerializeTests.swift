import XCTest
@testable import NTFSCore

/// AC-4 spec-conformance tests for `BootSector.serialize()`.
///
/// Hand-decoded reference bytes — these tests do NOT round-trip through
/// `BootSector.parse(_:)`. They assert that critical fields land at the
/// exact NTFS-spec offsets with the exact little-endian byte sequences
/// (PR #26 lesson: spec conformance is independent of our decoder).
final class BootSectorSerializeTests: XCTestCase {

    /// A representative 256 MiB NTFS volume:
    ///   - 512-byte sectors
    ///   - 8 sectors/cluster → 4096-byte clusters
    ///   - 524,288 sectors (= 256 MiB)
    ///   - MFT at cluster 4 (typical for small volumes), mirror at cluster N/2
    ///   - clustersPerMFTRecord = -10 → 2^10 = 1024-byte records
    ///   - clustersPerIndexRecord = 1
    ///   - volumeSerial = 0x0123_4567_89AB_CDEF
    private func referenceBootSector() -> BootSector {
        BootSector(
            oemID: "NTFS    ",
            bytesPerSector: 512,
            sectorsPerCluster: 8,
            mediaDescriptor: 0xF8,
            totalSectors: 524_288,
            mftCluster: 4,
            mftMirrorCluster: 32_768,
            clustersPerMFTRecord: -10,
            clustersPerIndexRecord: 1,
            volumeSerial: 0x0123_4567_89AB_CDEF
        )
    }

    func testSerializedLengthIs512() throws {
        let bs = referenceBootSector()
        let bytes = try bs.serialize()
        XCTAssertEqual(bytes.count, 512, "boot sector must be exactly 512 bytes")
    }

    func testJumpStubBytes() throws {
        // Canonical mkntfs jump stub: EB 52 90 (short jmp +0x52, NOP).
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[0], 0xEB, "jump opcode")
        XCTAssertEqual(bytes[1], 0x52, "jump offset")
        XCTAssertEqual(bytes[2], 0x90, "NOP")
    }

    func testOEMIDIsNTFSPlusSpaces() throws {
        let bytes = try referenceBootSector().serialize()
        // Bytes 3-10: "NTFS    " (4 + 4 spaces).
        let expected: [UInt8] = [0x4E, 0x54, 0x46, 0x53, 0x20, 0x20, 0x20, 0x20]
        for i in 0..<8 {
            XCTAssertEqual(bytes[3 + i], expected[i],
                           "OEMID byte \(i): expected 0x\(String(format: "%02X", expected[i])), got 0x\(String(format: "%02X", bytes[3+i]))")
        }
    }

    func testBytesPerSectorEncoding() throws {
        // bytesPerSector = 512 → offset 11: 00 02
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[11], 0x00)
        XCTAssertEqual(bytes[12], 0x02)
    }

    func testSectorsPerClusterAndMediaDescriptor() throws {
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[13], 0x08, "sectorsPerCluster = 8")
        XCTAssertEqual(bytes[21], 0xF8, "media descriptor = fixed disk")
    }

    func testTotalSectorsAt40() throws {
        // 524288 = 0x80000 → LE 8 bytes: 00 00 08 00 00 00 00 00
        let bytes = try referenceBootSector().serialize()
        let expected: [UInt8] = [0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]
        for i in 0..<8 {
            XCTAssertEqual(bytes[40 + i], expected[i], "totalSectors byte \(i)")
        }
    }

    func testMFTClusterAt48() throws {
        // mftCluster = 4 → LE 04 00 00 00 00 00 00 00
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[48], 0x04)
        for i in 1..<8 {
            XCTAssertEqual(bytes[48 + i], 0x00, "mftCluster byte \(i) padding")
        }
    }

    func testMFTMirrorClusterAt56() throws {
        // mftMirrorCluster = 32768 = 0x8000 → LE 00 80 00 00 00 00 00 00
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[56], 0x00)
        XCTAssertEqual(bytes[57], 0x80)
        for i in 2..<8 {
            XCTAssertEqual(bytes[56 + i], 0x00, "mftMirrorCluster byte \(i)")
        }
    }

    func testClustersPerMFTRecordEncoding() throws {
        // Signed-negative encoding: -10 → 0xF6.
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[64], 0xF6, "clustersPerMFTRecord = -10 → 0xF6")
    }

    func testClustersPerIndexRecordEncoding() throws {
        // +1 → 0x01.
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[68], 0x01)
    }

    func testVolumeSerialAt72() throws {
        // 0x0123456789ABCDEF → LE: EF CD AB 89 67 45 23 01
        let bytes = try referenceBootSector().serialize()
        let expected: [UInt8] = [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01]
        for i in 0..<8 {
            XCTAssertEqual(bytes[72 + i], expected[i], "volumeSerial byte \(i)")
        }
    }

    func testSignatureAt510() throws {
        let bytes = try referenceBootSector().serialize()
        XCTAssertEqual(bytes[510], 0x55, "signature byte 0")
        XCTAssertEqual(bytes[511], 0xAA, "signature byte 1")
    }

    func testRoundTripParse() throws {
        // Sanity: the serialized form should parse back to the same value
        // through our own decoder (this is NOT the AC-4 reference test —
        // it's a regression guard for parse/serialize symmetry).
        let bs = referenceBootSector()
        let bytes = try bs.serialize()
        let parsed = try BootSector.parse(bytes)
        XCTAssertEqual(parsed, bs)
    }

    func testRejectsNonNTFSOEM() throws {
        let bs = BootSector(
            oemID: "FAT32   ",
            bytesPerSector: 512, sectorsPerCluster: 8,
            mediaDescriptor: 0xF8, totalSectors: 1024,
            mftCluster: 1, mftMirrorCluster: 2,
            clustersPerMFTRecord: -10, clustersPerIndexRecord: 1,
            volumeSerial: 0
        )
        XCTAssertThrowsError(try bs.serialize())
    }

    func testRejectsBadSectorsPerCluster() throws {
        let bs = BootSector(
            oemID: "NTFS    ",
            bytesPerSector: 512, sectorsPerCluster: 3,  // not power of 2
            mediaDescriptor: 0xF8, totalSectors: 1024,
            mftCluster: 1, mftMirrorCluster: 2,
            clustersPerMFTRecord: -10, clustersPerIndexRecord: 1,
            volumeSerial: 0
        )
        XCTAssertThrowsError(try bs.serialize())
    }
}
