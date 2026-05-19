import XCTest
@testable import NTFSCore

final class AttributeListTests: XCTestCase {

    /// Build a single $ATTRIBUTE_LIST entry by hand (matching the spec
    /// layout exactly), then confirm we parse it back to the same logical
    /// value AND that our serializer round-trips byte-exact.
    func testRoundTripSimpleEntryNoName() throws {
        // Synthetic entry:
        //   type = 0xA0 ($INDEX_ALLOCATION)
        //   entry_length = 32 (26 raw + 0 name + padding to 32)
        //   name_length = 0
        //   name_offset = 0
        //   lowest_vcn = 0
        //   mft_reference = (sequence 0x0007 << 48) | recnum 0x00_01_23_45_67_89
        //   attribute_id = 5
        var bytes = Data(count: 32)
        MFTRecord.writeU32LE(into: &bytes, at: 0,  value: 0xA0)
        MFTRecord.writeU16LE(into: &bytes, at: 4,  value: 32)
        bytes[6] = 0
        bytes[7] = 0
        MFTRecord.writeU64LE(into: &bytes, at: 8,  value: 0)
        MFTRecord.writeU64LE(into: &bytes, at: 16, value: (UInt64(0x0007) << 48) | 0x0001_2345_6789)
        MFTRecord.writeU16LE(into: &bytes, at: 24, value: 5)

        let parsed = try AttributeListEntry.parseAll(in: bytes)
        XCTAssertEqual(parsed.count, 1)
        let e = parsed[0]
        XCTAssertEqual(e.attributeType, 0xA0)
        XCTAssertEqual(e.entryLength, 32)
        XCTAssertEqual(e.nameLength, 0)
        XCTAssertEqual(e.name, "")
        XCTAssertEqual(e.lowestVCN, 0)
        XCTAssertEqual(e.recordNumber, 0x0001_2345_6789)
        XCTAssertEqual(e.sequenceNumber, 0x0007)
        XCTAssertEqual(e.attributeID, 5)

        // Round-trip: serialize the parsed entry and confirm byte-equal.
        // Our `make()` helper rebuilds the entry from logical fields, then
        // serializes; result should match the synthetic bytes exactly.
        let rebuilt = AttributeListEntry.make(
            attributeType: e.attributeType,
            attributeName: e.name,
            recordNumber: e.recordNumber,
            sequenceNumber: e.sequenceNumber,
            attributeID: e.attributeID
        )
        XCTAssertEqual(rebuilt.serialize(), bytes)
    }

    /// Same as above but with the "$I30" name — checks the name region
    /// encoding + offset handling + 8-byte alignment.
    func testRoundTripEntryWithI30Name() throws {
        let entry = AttributeListEntry.make(
            attributeType: 0xA0,                  // $INDEX_ALLOCATION
            attributeName: "$I30",
            recordNumber: 42,
            sequenceNumber: 1,
            attributeID: 7
        )
        // 26 raw + 8 bytes name (4 UTF-16 code units × 2) = 34, rounded to 40.
        XCTAssertEqual(entry.entryLength, 40)
        XCTAssertEqual(entry.nameLength, 4)
        XCTAssertEqual(entry.nameOffset, 26)

        let serialized = entry.serialize()
        XCTAssertEqual(serialized.count, 40)

        let parsed = try AttributeListEntry.parseAll(in: serialized)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "$I30")
        XCTAssertEqual(parsed[0].attributeType, 0xA0)
        XCTAssertEqual(parsed[0].recordNumber, 42)
        XCTAssertEqual(parsed[0].sequenceNumber, 1)
        XCTAssertEqual(parsed[0].attributeID, 7)
    }

    /// A real-world $ATTRIBUTE_LIST body has multiple entries. Confirm we
    /// walk all of them and stop cleanly on a zero-length terminator (some
    /// implementations write one; ours doesn't, but be tolerant).
    func testParseMultipleEntries() throws {
        let entries = [
            AttributeListEntry.make(attributeType: 0x10, attributeName: "",     recordNumber: 5, sequenceNumber: 1, attributeID: 0),
            AttributeListEntry.make(attributeType: 0x30, attributeName: "",     recordNumber: 5, sequenceNumber: 1, attributeID: 1),
            AttributeListEntry.make(attributeType: 0x90, attributeName: "$I30", recordNumber: 5, sequenceNumber: 1, attributeID: 2),
            AttributeListEntry.make(attributeType: 0xA0, attributeName: "$I30", recordNumber: 42, sequenceNumber: 1, attributeID: 3),
            AttributeListEntry.make(attributeType: 0xB0, attributeName: "$I30", recordNumber: 5, sequenceNumber: 1, attributeID: 4),
        ]
        let body = serializeAttributeListBody(entries)
        let parsed = try AttributeListEntry.parseAll(in: body)
        XCTAssertEqual(parsed.count, 5)
        XCTAssertEqual(parsed.map(\.attributeType), [0x10, 0x30, 0x90, 0xA0, 0xB0])
        XCTAssertEqual(parsed[3].recordNumber, 42)   // the migrated $INDEX_ALLOCATION
        XCTAssertEqual(parsed[3].name, "$I30")
    }

    /// Defensive: malformed entry_length (0 or < 26) terminates the walk
    /// cleanly rather than throwing or looping forever.
    func testTerminatesOnZeroLengthEntry() throws {
        let normal = AttributeListEntry.make(
            attributeType: 0x10, attributeName: "", recordNumber: 5, sequenceNumber: 1, attributeID: 0
        ).serialize()
        // Append a 4-byte zero block — looks like a "type=0, length=0" terminator.
        var bytes = normal
        bytes.append(Data(count: 4))
        let parsed = try AttributeListEntry.parseAll(in: bytes)
        XCTAssertEqual(parsed.count, 1)
    }
}
