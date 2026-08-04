import XCTest
@testable import NTFSCore

/// v0.7.4 — the data-run **length** field must be encoded signed-safe.
///
/// NTFS documents the run length as an unsigned cluster count, and decoding
/// it unsigned is correct. But Windows *decodes it as signed*, so an encoder
/// that emits the minimal unsigned width produces a field Windows reads as
/// negative whenever the top byte's high bit is set — a 184-cluster run
/// encoded as the single byte `b8` instead of `b8 00`.
///
/// Hardware evidence (`chkdsk` on a 7.9 GB Windows-formatted stick carrying
/// 11,500 files): **41 of 10,045** records were reported as
/// `Attribute record (80, "") from file record segment N is corrupt`, and
/// the set correlated *perfectly* — 41/41 flagged, 10,004/10,004 clean —
/// with "some run's length field has bit 7 set in its top byte". Every
/// affected file fell in the [128, 255]-cluster band (~512 KiB–1 MiB).
///
/// `verify --deep` passed the same volume with zero findings, because our
/// own decoder reads the field unsigned and a leading `00` decodes
/// identically. Only an external NTFS implementation could see it.
final class RunlistSignedLengthTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        return FileManager.default.fileExists(
            atPath: here.deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent(name).path
        )
    }

    /// Walk the raw runlist bytes of a non-resident attribute and return each
    /// run's (lengthWidth, topLengthByte, clusterCount).
    private func runLengthFields(
        recordBytes: Data, attrOffset: Int, attrLength: Int, dataRunsOffset: Int
    ) -> [(width: Int, topByte: UInt8, count: UInt64)] {
        let base = recordBytes.startIndex
        var i = base + attrOffset + dataRunsOffset
        let end = base + attrOffset + attrLength
        var out: [(Int, UInt8, UInt64)] = []
        while i < end {
            let header = recordBytes[i]
            if header == 0 { break }
            let lengthWidth = Int(header & 0x0F)
            let offsetWidth = Int(header >> 4)
            i += 1
            guard lengthWidth > 0, i + lengthWidth + offsetWidth <= end else { break }
            var count: UInt64 = 0
            for k in 0..<lengthWidth {
                count |= UInt64(recordBytes[i + k]) << (8 * k)
            }
            out.append((lengthWidth, recordBytes[i + lengthWidth - 1], count))
            i += lengthWidth + offsetWidth
        }
        return out
    }

    /// Find the first attribute of `rawType` in the raw attribute stream,
    /// returning its byte offset and length within the record.
    private func locateAttribute(
        in bytes: Data, rawType: UInt32, firstAttributeOffset: Int, usedSize: Int
    ) -> (offset: Int, length: Int)? {
        let base = bytes.startIndex
        var cursor = firstAttributeOffset
        let limit = min(usedSize, bytes.count)
        func u32(_ at: Int) -> UInt32 {
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(bytes[base + at + k]) << (8 * k) }
            return v
        }
        while cursor + 8 <= limit {
            let type = u32(cursor)
            if type == 0xFFFF_FFFF { return nil }
            let length = Int(u32(cursor + 4))
            guard length >= 16, cursor + length <= limit else { return nil }
            if type == rawType { return (cursor, length) }
            cursor += length
        }
        return nil
    }

    func testRunLengthFieldIsNeverEncodedWithHighBitSet() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let volume = try await Volume(
            device: try FileHandleBlockDevice(openingFileForUpdateAt: path)
        )

        // 200 clusters lands squarely in the [128, 255] danger band on any
        // cluster size: minimal-unsigned encoding is the single byte 0xC8
        // (bit 7 set), which is exactly what chkdsk rejected on hardware.
        let clusters: UInt64 = 200
        let total = Int(clusters * UInt64(volume.bytesPerCluster)) - 33
        let rn = try await volume.createFile(named: "signed-run.bin", inDirectory: 5)

        var payload = Data(count: total)
        for i in 0..<total { payload[i] = UInt8((i &* 17 &+ 3) & 0xFF) }
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            defer { cursor += take }
            return payload.subdata(in: cursor..<(cursor + take))
        }

        // Assert the PERSISTED bytes, re-read from disk.
        let reopen = try await Volume(
            device: try FileHandleBlockDevice(openingFileAt: path)
        )
        let record = try await reopen.mft().record(at: rn)
        let attrs = try record.attributes()
        guard let data = attrs.first(where: {
            $0.type == .data && $0.nameOrEmpty == ""
        }) else {
            return XCTFail("no unnamed $DATA on record \(rn)")
        }
        guard case let .nonResident(_, _, dataRunsOffset, _, _, _, _, extents) = data.value else {
            return XCTFail("$DATA unexpectedly resident — fixture too small to exercise runs")
        }

        // `Attribute` doesn't carry its offset within the record, so walk the
        // raw attribute stream to find where the unnamed $DATA physically is.
        guard let located = locateAttribute(
            in: record.bytes,
            rawType: AttributeType.data.rawValue,
            firstAttributeOffset: Int(record.firstAttributeOffset),
            usedSize: Int(record.usedSize)
        ) else {
            return XCTFail("could not locate $DATA in the raw record stream")
        }

        let fields = runLengthFields(
            recordBytes: record.bytes,
            attrOffset: located.offset,
            attrLength: located.length,
            dataRunsOffset: Int(dataRunsOffset)
        )
        XCTAssertFalse(fields.isEmpty, "no data runs decoded from the persisted record")

        for (width, topByte, count) in fields {
            XCTAssertEqual(
                topByte & 0x80, 0,
                """
                run length \(count) encoded in \(width) byte(s) with top byte \
                0x\(String(topByte, radix: 16)) — bit 7 set. Windows decodes this \
                field as SIGNED and will reject the attribute as corrupt. \
                Widen by one zero byte.
                """
            )
        }

        // The invariant must not come at the cost of correctness: the runs
        // still describe the same allocation, and content round-trips.
        let encodedClusters = fields.reduce(UInt64(0)) { $0 + $1.count }
        let extentClusters = extents.reduce(UInt64(0)) { $0 + $1.clusterCount }
        XCTAssertEqual(
            encodedClusters, extentClusters,
            "signed-safe widening must not change the decoded cluster count"
        )

        let readBack = try await reopen.readFile(at: rn)
        XCTAssertEqual(readBack.count, total, "read-back length mismatch")
        XCTAssertEqual(readBack, payload, "content must survive the re-encoding")

        // The danger band is the point of the test — if the allocator handed
        // us only small runs, the assertions above proved nothing.
        XCTAssertTrue(
            fields.contains { (128...255).contains($0.count) },
            "fixture produced no run in the [128,255]-cluster band; got \(fields.map { $0.count })"
        )
    }
}
