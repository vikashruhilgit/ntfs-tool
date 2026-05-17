import XCTest
@testable import NTFSCore

/// MFT-level create/delete round-trip tests on the mutable fixture.
/// Block G stage 3a: validates the MFT mutation path. Stage 3b will add
/// $I30 index wiring so created files are visible to enumerate().
final class FileCreateDeleteTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    func testUSAReverseFixupRoundTrip() throws {
        // Take an existing MFT record from the fixture, serialize it, and
        // re-parse — the round-trip should produce identical attribute output.
        // (No fixture needed — we hand-build a record.)
        let builder = MFTRecordBuilder(
            recordSize: 1024,
            sectorSize: 512,
            recordNumber: 100,
            sequenceNumber: 7,
            isDirectory: false,
            fileName: "test.txt",
            parentReference: (UInt64(1) << 48) | 5,
            nowFiletime: 134_105_760_000_000_000   // 2026-01-01 UTC
        )
        let postFixup = try builder.build()

        // Reverse USA → real on-disk form.
        let onDisk = try UpdateSequenceArray.reverseFixup(
            recordBytes: postFixup,
            usaOffset: 48,
            usaCount: 3,
            blockSize: 512
        )
        // Now parse the on-disk form. It should pass USA verification.
        let parsed = try MFTRecord.parse(onDisk, expectedSize: 1024, sectorSize: 512)
        XCTAssertEqual(parsed.magic, MFTRecord.magicFILE)
        XCTAssertTrue(parsed.isInUse)
        XCTAssertEqual(parsed.sequenceNumber, 7)
        XCTAssertEqual(parsed.mftRecordNumber, 100)
        XCTAssertEqual(parsed.hardLinkCount, 1)

        let attrs = try parsed.attributes()
        XCTAssertEqual(attrs.count, 3, "expected $STANDARD_INFO + $FILE_NAME + $DATA")
        XCTAssertEqual(attrs[0].type, .standardInformation)
        XCTAssertEqual(attrs[1].type, .fileName)
        XCTAssertEqual(attrs[2].type, .data)

        guard case let .resident(fnBytes, _) = attrs[1].value else {
            return XCTFail("$FILE_NAME should be resident")
        }
        let fileName = try FileName.parse(fnBytes)
        XCTAssertEqual(fileName.name, "test.txt")
        XCTAssertEqual(fileName.parentRecordNumber, 5)
    }

    func testCreateFileWritesParseableMFTRecord() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Snapshot the MFT slot at the next free position before the create.
        let firstFree = try await mft.findFreeRecordNumber()
        let recordNumber = try await volume.createFile(named: "created.txt", inDirectory: 5)
        XCTAssertEqual(recordNumber, firstFree)

        // Re-read via a fresh BlockDevice so we know the write hit disk.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let reopenedMFT = await reopenedVolume.mft()
        let created = try await reopenedMFT.record(at: recordNumber)

        XCTAssertTrue(created.isInUse, "new record should be IN_USE")
        XCTAssertFalse(created.isDirectory, "default create is a file")
        XCTAssertEqual(created.mftRecordNumber, UInt32(recordNumber))

        let attrs = try created.attributes()
        XCTAssertEqual(attrs.count, 3, "should have $STANDARD_INFO + $FILE_NAME + $DATA")

        guard let fnAttr = attrs.first(where: { $0.type == .fileName }),
              case let .resident(fnBytes, _) = fnAttr.value
        else {
            return XCTFail("missing $FILE_NAME")
        }
        let fileName = try FileName.parse(fnBytes)
        XCTAssertEqual(fileName.name, "created.txt")
        XCTAssertEqual(fileName.parentRecordNumber, 5)

        // $DATA should be resident + empty.
        guard let dataAttr = attrs.first(where: { $0.type == .data }),
              case let .resident(dataBytes, _) = dataAttr.value
        else {
            return XCTFail("missing $DATA")
        }
        XCTAssertEqual(dataBytes.count, 0, "fresh file's $DATA should be empty")
    }

    func testDeleteFileFlipsInUseOff() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        // Create then immediately delete.
        let recordNumber = try await volume.createFile(named: "ephemeral.txt", inDirectory: 5)
        let beforeDelete = try await mft.record(at: recordNumber)
        XCTAssertTrue(beforeDelete.isInUse)
        let seqBeforeDelete = beforeDelete.sequenceNumber

        try await volume.deleteFile(at: recordNumber)

        // Re-read via fresh device.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let reopenedMFT = await reopenedVolume.mft()
        let deleted = try await reopenedMFT.record(at: recordNumber)

        XCTAssertFalse(deleted.isInUse, "record should be IN_USE=0 after delete")
        XCTAssertNotEqual(deleted.sequenceNumber, seqBeforeDelete,
                          "sequence number should bump on delete")
    }

    func testDeleteRejectsSystemRecords() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // MFT records 0-15 are reserved system files. Deletion must refuse.
        for n: UInt64 in [0, 5, 6, 11, 15] {
            do {
                try await volume.deleteFile(at: n)
                XCTFail("expected refusal to delete reserved record \(n)")
            } catch NTFSError.unsupportedFeature {
                // expected
            }
        }
    }

    func testCreateDeleteRoundTripFreesMFTSlot() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()

        let originalFirstFree = try await mft.findFreeRecordNumber()

        // Create N files, delete them, verify the slots are all free again.
        let names = ["a.txt", "b.txt", "c.txt"]
        var assignedSlots: [UInt64] = []
        for name in names {
            let recordNumber = try await volume.createFile(named: name, inDirectory: 5)
            assignedSlots.append(recordNumber)
        }
        XCTAssertEqual(Set(assignedSlots).count, names.count,
                       "create should hand out distinct MFT slots")

        for slot in assignedSlots {
            try await volume.deleteFile(at: slot)
        }

        // After all deletes, the original first-free slot should be free again.
        let postFirstFree = try await mft.findFreeRecordNumber()
        XCTAssertEqual(postFirstFree, originalFirstFree,
                       "deleting all created files should restore first-free pointer")
    }
}
