import XCTest
@testable import NTFSCore

final class DataRunTests: XCTestCase {

    /// Encode a single data-run header byte from offset/length widths.
    /// Layout: low nibble = length width, high nibble = offset width.
    private static func headerByte(lengthWidth: UInt8, offsetWidth: UInt8) -> UInt8 {
        return (offsetWidth << 4) | (lengthWidth & 0x0F)
    }

    /// Build a runlist of 3 mixed runs:
    ///   1) 8 clusters at LCN 100      (normal, positive delta from 0)
    ///   2) 4 clusters at LCN 95       (negative delta of -5 from prev)
    ///   3) 6 clusters sparse          (no offset bytes)
    /// Then 0x00 terminator.
    private static func mixedRunlist() -> Data {
        var bytes: [UInt8] = []

        // Run 1: header 0x21 (1 length byte, 2 offset bytes); length=8; offset=100 (LE u16 = 0x64 0x00)
        bytes.append(headerByte(lengthWidth: 1, offsetWidth: 2))
        bytes.append(0x08)             // length = 8
        bytes.append(0x64); bytes.append(0x00)  // offset = +100 (LE)

        // Run 2: header 0x11 (1 length byte, 1 offset byte); length=4; offset=-5 (signed i8 = 0xFB)
        bytes.append(headerByte(lengthWidth: 1, offsetWidth: 1))
        bytes.append(0x04)             // length = 4
        bytes.append(0xFB)             // offset = -5 (sign-extended)

        // Run 3: header 0x01 (1 length byte, 0 offset bytes = sparse); length=6
        bytes.append(headerByte(lengthWidth: 1, offsetWidth: 0))
        bytes.append(0x06)             // length = 6

        // Terminator
        bytes.append(0x00)

        return Data(bytes)
    }

    func testDecodeMixedRunlist() throws {
        let extents = try DataRun.decode(Self.mixedRunlist())
        XCTAssertEqual(extents.count, 3)

        // Run 1: 8 clusters starting at LCN 100
        XCTAssertEqual(extents[0].startLCN, 100)
        XCTAssertEqual(extents[0].clusterCount, 8)
        XCTAssertFalse(extents[0].isSparse)

        // Run 2: 4 clusters starting at LCN 95 (100 - 5)
        XCTAssertEqual(extents[1].startLCN, 95)
        XCTAssertEqual(extents[1].clusterCount, 4)

        // Run 3: 6 sparse clusters
        XCTAssertNil(extents[2].startLCN)
        XCTAssertEqual(extents[2].clusterCount, 6)
        XCTAssertTrue(extents[2].isSparse)

        XCTAssertEqual(DataRun.totalClusters(extents), 18)
    }

    func testEmptyRunlist() throws {
        // Just a terminator.
        let extents = try DataRun.decode(Data([0x00]))
        XCTAssertEqual(extents.count, 0)
    }

    func testSingleRunWithoutTerminator() throws {
        // Some NTFS variants omit the trailing 0x00 if the runlist exactly fills
        // the attribute slot. Decoder should still succeed when we run out of bytes.
        var bytes: [UInt8] = []
        bytes.append(Self.headerByte(lengthWidth: 1, offsetWidth: 1))
        bytes.append(0x10)             // length = 16
        bytes.append(0x20)             // offset = +32

        let extents = try DataRun.decode(Data(bytes))
        XCTAssertEqual(extents.count, 1)
        XCTAssertEqual(extents[0].startLCN, 32)
        XCTAssertEqual(extents[0].clusterCount, 16)
    }

    func testTruncatedRunlistRejected() throws {
        // Header says 2 length bytes but we only provide 1.
        let truncated = Data([
            Self.headerByte(lengthWidth: 2, offsetWidth: 1),
            0x10  // missing second length byte + the offset byte
        ])
        XCTAssertThrowsError(try DataRun.decode(truncated)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testRejectsZeroLengthWidthHeader() throws {
        // Header 0x10: length width = 0 — invalid (must be >= 1).
        let invalid = Data([0x10, 0x00])
        XCTAssertThrowsError(try DataRun.decode(invalid)) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }

    func testRejectsNegativeAbsoluteLCN() throws {
        // First run has a negative offset, which would produce a negative starting LCN —
        // not valid for the first extent.
        let bytes: [UInt8] = [
            Self.headerByte(lengthWidth: 1, offsetWidth: 1),
            0x08,
            0xFF   // -1 from previous (0) → -1 LCN
        ]
        XCTAssertThrowsError(try DataRun.decode(Data(bytes))) { error in
            guard case NTFSError.corruptOnDisk = error else {
                return XCTFail("expected corruptOnDisk, got \(error)")
            }
        }
    }
}
