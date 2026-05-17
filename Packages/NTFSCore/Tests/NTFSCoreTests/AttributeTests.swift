import XCTest
@testable import NTFSCore

final class AttributeTests: XCTestCase {

    private func fixturePath(_ name: String) -> String {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }

    /// Build a hand-crafted MFT record containing exactly one resident $STANDARD_INFORMATION
    /// attribute (type 0x10) with a 48-byte value, followed by the 0xFFFFFFFF end marker.
    private static func recordWithStandardInformation() -> Data {
        var data = Data(repeating: 0, count: 1024)

        func writeU16(at o: Int, _ v: UInt16) {
            data[o] = UInt8(v & 0xFF); data[o + 1] = UInt8((v >> 8) & 0xFF)
        }
        func writeU32(at o: Int, _ v: UInt32) {
            for i in 0..<4 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func writeU64(at o: Int, _ v: UInt64) {
            for i in 0..<8 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }

        // MFT record header (matches the layout used in MFTTests).
        writeU32(at: 0, MFTRecord.magicFILE)
        writeU16(at: 4, 48)         // usaOffset
        writeU16(at: 6, 3)          // usaCount (1 sentinel + 2 fixups)
        writeU64(at: 8, 0xAAAA_BBBB)
        writeU16(at: 16, 1)
        writeU16(at: 18, 1)
        writeU16(at: 20, 56)        // firstAttributeOffset
        writeU16(at: 22, 0x0001)    // IN_USE
        // Resident SI attribute: 16-byte header + 8-byte resident extension + 48-byte value = 72 bytes
        // usedSize is bytes used FROM RECORD START: 56 (firstAttributeOffset) + 72 (attr) + 4 (end marker) = 132
        writeU32(at: 24, 56 + 72 + 4)
        writeU32(at: 28, 1024)
        writeU64(at: 32, 0)
        writeU16(at: 40, 5)
        writeU32(at: 44, 0)

        // USA at 48
        writeU16(at: 48, 0xCAFE)
        writeU16(at: 50, 0xDEAD)
        writeU16(at: 52, 0xBEEF)

        // Block-tail sentinels for USA fix-up.
        writeU16(at: 510, 0xCAFE)
        writeU16(at: 1022, 0xCAFE)

        // Attribute at offset 56: $STANDARD_INFORMATION, resident, value at offset 24.
        let attrStart = 56
        writeU32(at: attrStart + 0, 0x10)      // type
        writeU32(at: attrStart + 4, 72)        // length (header 16 + resident ext 8 + value 48)
        data[attrStart + 8]  = 0               // non-resident flag = 0
        data[attrStart + 9]  = 0               // name length
        writeU16(at: attrStart + 10, 0)        // name offset
        writeU16(at: attrStart + 12, 0)        // flags
        writeU16(at: attrStart + 14, 0)        // attribute ID

        // Resident extension
        writeU32(at: attrStart + 16, 48)       // value length
        writeU16(at: attrStart + 20, 24)       // value offset (relative to attribute start)
        data[attrStart + 22] = 0               // indexed
        data[attrStart + 23] = 0               // padding

        // Value: fill with a recognizable pattern at attrStart + 24..72
        for i in 0..<48 {
            data[attrStart + 24 + i] = UInt8(0x40 + i)
        }

        // End marker at attrStart + 72 = offset 128
        writeU32(at: attrStart + 72, AttributeType.endMarker)

        return data
    }

    /// Hand-crafted MFT record holding a single non-resident $DATA attribute
    /// whose runlist payload is the same three-run mix tested in DataRunTests
    /// (normal positive delta, negative delta, sparse). Exercises the
    /// Attribute → DataRun handoff and dataRunsOffset-relative slicing
    /// without depending on the live fixture.
    private static func recordWithNonResidentData() -> Data {
        var data = Data(repeating: 0, count: 1024)

        func writeU16(at o: Int, _ v: UInt16) {
            data[o] = UInt8(v & 0xFF); data[o + 1] = UInt8((v >> 8) & 0xFF)
        }
        func writeU32(at o: Int, _ v: UInt32) {
            for i in 0..<4 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func writeU64(at o: Int, _ v: UInt64) {
            for i in 0..<8 { data[o + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }

        // MFT record header.
        writeU32(at: 0, MFTRecord.magicFILE)
        writeU16(at: 4, 48)          // usaOffset
        writeU16(at: 6, 3)           // usaCount
        writeU64(at: 8, 0xAAAA_BBBB) // LSN
        writeU16(at: 16, 1)          // sequence
        writeU16(at: 18, 1)          // hardLinkCount
        writeU16(at: 20, 56)         // firstAttributeOffset

        // Non-resident attribute is 16 (common header) + 48 (non-resident
        // extension) + runlist bytes. Our runlist payload is 11 bytes
        // (3 runs: 1+1+2=4, 1+1+1=3, 1+1=2, plus 0x00 terminator = 11).
        // Round attribute length up to 8-byte alignment: 64 + 11 = 75 → 80.
        let attrLength: UInt32 = 80
        writeU16(at: 22, 0x0001)     // IN_USE
        writeU32(at: 24, UInt32(56) + attrLength + 4) // usedSize = firstAttrOffset + attr + end marker
        writeU32(at: 28, 1024)
        writeU64(at: 32, 0)
        writeU16(at: 40, 5)
        writeU32(at: 44, 0)

        // USA at 48.
        writeU16(at: 48, 0xCAFE)
        writeU16(at: 50, 0xDEAD)
        writeU16(at: 52, 0xBEEF)

        // Block-tail sentinels for USA fix-up.
        writeU16(at: 510, 0xCAFE)
        writeU16(at: 1022, 0xCAFE)

        // Non-resident $DATA attribute at offset 56.
        let attrStart = 56
        writeU32(at: attrStart + 0, 0x80)        // type = $DATA
        writeU32(at: attrStart + 4, attrLength)  // length
        data[attrStart + 8]  = 1                 // non-resident flag
        data[attrStart + 9]  = 0                 // name length
        writeU16(at: attrStart + 10, 0)          // name offset
        writeU16(at: attrStart + 12, 0)          // flags
        writeU16(at: attrStart + 14, 0)          // attribute ID

        // Non-resident extension (offsets relative to attribute start).
        writeU64(at: attrStart + 16, 0)          // startingVCN
        writeU64(at: attrStart + 24, 17)         // lastVCN = 8+4+6-1 = 17
        writeU16(at: attrStart + 32, 64)         // dataRunsOffset (right after the ext)
        data[attrStart + 34] = 0                 // compressionUnit
        writeU32(at: attrStart + 40, 18 * 4096)  // allocatedSize (18 clusters × 4096)
        writeU64(at: attrStart + 40, UInt64(18 * 4096))
        writeU64(at: attrStart + 48, UInt64(17 * 4096) + 100)  // realSize (arbitrary < allocated)
        writeU64(at: attrStart + 56, UInt64(17 * 4096) + 100)  // initializedSize

        // Runlist at attrStart + 64 — same encoding as DataRunTests.mixedRunlist():
        //   run 1: 0x21 / length=8 / offset=+100 (LE u16 = 0x64 0x00)
        //   run 2: 0x11 / length=4 / offset=-5  (i8 = 0xFB)
        //   run 3: 0x01 / length=6                (sparse)
        //   terminator: 0x00
        let runsStart = attrStart + 64
        data[runsStart + 0]  = 0x21
        data[runsStart + 1]  = 0x08
        data[runsStart + 2]  = 0x64
        data[runsStart + 3]  = 0x00
        data[runsStart + 4]  = 0x11
        data[runsStart + 5]  = 0x04
        data[runsStart + 6]  = 0xFB
        data[runsStart + 7]  = 0x01
        data[runsStart + 8]  = 0x06
        data[runsStart + 9]  = 0x00
        // remaining bytes through attrStart + 80 stay zero (padding)

        // End marker.
        writeU32(at: attrStart + Int(attrLength), AttributeType.endMarker)

        return data
    }

    func testIterateSingleNonResidentDataAttribute() throws {
        let raw = Self.recordWithNonResidentData()
        let record = try MFTRecord.parse(raw, expectedSize: 1024)
        let attrs = try record.attributes()

        XCTAssertEqual(attrs.count, 1)
        let dataAttr = attrs[0]
        XCTAssertEqual(dataAttr.type, .data)
        XCTAssertTrue(dataAttr.header.nonResident)
        XCTAssertEqual(dataAttr.header.length, 80)

        guard case let .nonResident(startingVCN, lastVCN, dataRunsOffset, _, _, _, _, extents) = dataAttr.value else {
            return XCTFail("expected non-resident value")
        }
        XCTAssertEqual(startingVCN, 0)
        XCTAssertEqual(lastVCN, 17)
        XCTAssertEqual(dataRunsOffset, 64)

        XCTAssertEqual(extents.count, 3)
        XCTAssertEqual(extents[0].startLCN, 100)
        XCTAssertEqual(extents[0].clusterCount, 8)
        XCTAssertEqual(extents[1].startLCN, 95)        // 100 + (-5)
        XCTAssertEqual(extents[1].clusterCount, 4)
        XCTAssertNil(extents[2].startLCN)              // sparse
        XCTAssertEqual(extents[2].clusterCount, 6)
    }

    func testIterateSingleResidentAttribute() throws {
        let raw = Self.recordWithStandardInformation()
        let record = try MFTRecord.parse(raw, expectedSize: 1024)
        let attrs = try record.attributes()

        XCTAssertEqual(attrs.count, 1, "expected exactly one attribute (end marker should halt iteration)")
        let si = attrs[0]
        XCTAssertEqual(si.rawType, 0x10)
        XCTAssertEqual(si.type, .standardInformation)
        XCTAssertFalse(si.header.nonResident)
        XCTAssertEqual(si.header.length, 72)
        XCTAssertEqual(si.header.attributeID, 0)
        XCTAssertNil(si.header.name)

        guard case let .resident(value, indexed) = si.value else {
            return XCTFail("expected resident value")
        }
        XCTAssertEqual(value.count, 48)
        XCTAssertEqual(value[0], 0x40)
        XCTAssertEqual(value[47], 0x40 + 47)
        XCTAssertFalse(indexed)
    }

    // MARK: — Live fixture

    /// Block C's signature test: read $MFT (record 0), find its $DATA attribute, decode
    /// the runlist, assert the first extent's startLCN matches the boot sector's
    /// mftCluster — that is, the volume's own self-description is internally consistent.
    func testMFTDataAttributeFirstExtentMatchesBootSector() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        let mftSelf = try await mft.record(at: 0)
        let attrs = try mftSelf.attributes()

        guard let dataAttr = attrs.first(where: { $0.type == .data }) else {
            return XCTFail("$MFT record 0 should contain a $DATA attribute, found: \(attrs.map { $0.type ?? .standardInformation })")
        }
        XCTAssertTrue(dataAttr.header.nonResident, "$MFT $DATA must be non-resident")

        guard case let .nonResident(_, _, _, _, _, _, _, extents) = dataAttr.value else {
            return XCTFail("expected non-resident value")
        }
        XCTAssertFalse(extents.isEmpty, "MFT must have at least one extent")
        XCTAssertEqual(
            extents[0].startLCN, volume.boot.mftCluster,
            "first extent of $MFT $DATA should start at boot.mftCluster (got \(String(describing: extents[0].startLCN)), expected \(volume.boot.mftCluster))"
        )
        XCTAssertGreaterThan(extents[0].clusterCount, 0)
    }

    func testRootDirectoryHasFileNameAttribute() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        let root = try await mft.record(at: 5)
        let attrs = try root.attributes()

        guard let fnAttr = attrs.first(where: { $0.type == .fileName }) else {
            return XCTFail("root directory should have a $FILE_NAME attribute, types: \(attrs.map { $0.rawType })")
        }
        guard case let .resident(value, _) = fnAttr.value else {
            return XCTFail("$FILE_NAME must be resident")
        }
        let fn = try FileName.parse(value)
        // The root directory's parent reference points to itself: MFT record 5.
        XCTAssertEqual(fn.parentRecordNumber, 5, "root directory's parent reference should be record 5 (self)")
        XCTAssertEqual(fn.name, ".", "root directory's $FILE_NAME should be '.'")
    }

    func testHelloTxtFileNameInMFT() async throws {
        let path = fixturePath("small.img")
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let device = try FileHandleBlockDevice(openingFileAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Sweep records 16..127 looking for the file named "hello.txt" we placed
        // into the fixture via make_test_images.sh. Unallocated records may contain
        // zeroed bytes that fail the FILE magic check — catch and skip them rather
        // than letting the parse error abort the sweep.
        var foundHello = false
        for n in UInt64(16)...UInt64(127) {
            let record: MFTRecord
            do {
                record = try await mft.record(at: n)
            } catch {
                continue   // unallocated / zeroed MFT slot — skip
            }
            guard record.isInUse else { continue }
            let attrs: [Attribute]
            do {
                attrs = try record.attributes()
            } catch {
                continue   // record corrupt or extension record we can't decode yet
            }
            for attr in attrs where attr.type == .fileName {
                guard case let .resident(value, _) = attr.value else { continue }
                guard let fn = try? FileName.parse(value) else { continue }
                if fn.name == "hello.txt" {
                    foundHello = true
                    XCTAssertEqual(fn.parentRecordNumber, 5, "hello.txt's parent is the root directory (record 5)")
                    // Note: $FILE_NAME's realSize/allocatedSize are populated at
                    // file creation time and NOT kept in sync with subsequent
                    // $DATA writes (NTFS-by-design — the canonical size lives
                    // in $DATA). On our fixture, hello.txt was written after
                    // creation so fn.realSize is 0, which is correct.
                    XCTAssertNotEqual(fn.namespace, .dos, "expected Win32 namespace for non-8.3 file name")
                }
            }
            if foundHello { break }
        }
        XCTAssertTrue(foundHello, "expected to find 'hello.txt' $FILE_NAME in MFT records 16..127")
    }
}
