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

    /// Find a small-enough subdirectory's MFT record number. The fixture's
    /// root is LARGE_INDEX (it has 15 entries — 12 system files + 3 user
    /// files); our resident-only $I30 mutation path correctly rejects it.
    /// The `sub/` subdirectory contains only `nested.txt` so its $I30 stays
    /// resident — use that as the parent for create/delete tests.
    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/' — regenerate via scripts/make_test_images.sh")
        }
        return sub.recordNumber
    }

    func testCreateFileWritesParseableMFTRecord() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()
        let parentRN = try await subDirRecordNumber(volume: volume)

        // Snapshot the MFT slot at the next free position before the create.
        let firstFree = try await mft.findFreeRecordNumber()
        let recordNumber = try await volume.createFile(named: "created.txt", inDirectory: parentRN)
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
        // Parent record is `sub/` (not root) since the fixture's root has
        // LARGE_INDEX which stage 3b doesn't yet support.
        XCTAssertEqual(fileName.parentRecordNumber, parentRN)

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
        let parentRN = try await subDirRecordNumber(volume: volume)

        // Create then immediately delete.
        let recordNumber = try await volume.createFile(named: "ephemeral.txt", inDirectory: parentRN)
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

    // MARK: — Stage 3b: $I30 wiring round-trips

    /// Created file appears in enumerate() of its parent.
    func testCreatedFileVisibleInEnumerate() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let beforeNames = Set(try await volume.enumerate(directory: parentRN).map { $0.name })
        XCTAssertFalse(beforeNames.contains("via-i30.txt"))

        _ = try await volume.createFile(named: "via-i30.txt", inDirectory: parentRN)

        // Re-open via fresh device — proves the $I30 update persisted.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let afterNames = Set(try await reopenedVolume.enumerate(directory: parentRN).map { $0.name })
        XCTAssertTrue(
            afterNames.contains("via-i30.txt"),
            "expected 'via-i30.txt' in parent enumerate after create; got \(afterNames)"
        )
    }

    /// After create + delete, the entry is gone from enumerate again.
    func testDeletedFileGoneFromEnumerate() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let recordNumber = try await volume.createFile(named: "ephemeral.txt", inDirectory: parentRN)
        let midNames = Set(try await volume.enumerate(directory: parentRN).map { $0.name })
        XCTAssertTrue(midNames.contains("ephemeral.txt"))

        try await volume.deleteFile(at: recordNumber)

        let afterNames = Set(try await volume.enumerate(directory: parentRN).map { $0.name })
        XCTAssertFalse(
            afterNames.contains("ephemeral.txt"),
            "expected 'ephemeral.txt' absent from parent enumerate after delete; got \(afterNames)"
        )
    }

    /// Inserting into a LARGE_INDEX directory (the fixture's root) descends
    /// the $INDEX_ALLOCATION B-tree and rewrites the right leaf in place.
    /// Verifies that the new file appears in the directory enumeration and
    /// that a follow-up delete cleanly removes it.
    func testCreateInLargeIndexSucceeds() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Create into the LARGE_INDEX root directory (recnum 5).
        let recordNumber = try await volume.createFile(named: "into-root.txt", inDirectory: 5)
        XCTAssertGreaterThanOrEqual(recordNumber, 16, "new file should land in user-record range")

        // Re-open the volume so we read from disk, not in-memory state.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        let names = entries.map { $0.name }
        XCTAssertTrue(
            names.contains("into-root.txt"),
            "newly-created file should appear in LARGE_INDEX root enumeration; got \(names)"
        )

        // Round-trip delete: file should disappear from the enumeration.
        try await reopened.deleteFile(at: recordNumber)
        let after = try await reopened.enumerate(directory: 5)
        XCTAssertFalse(
            after.map { $0.name }.contains("into-root.txt"),
            "deleted file should not appear in LARGE_INDEX root enumeration"
        )
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
        let parentRN = try await subDirRecordNumber(volume: volume)

        let originalFirstFree = try await mft.findFreeRecordNumber()

        // Create N files, delete them, verify the slots are all free again.
        let names = ["a.txt", "b.txt", "c.txt"]
        var assignedSlots: [UInt64] = []
        for name in names {
            let recordNumber = try await volume.createFile(named: name, inDirectory: parentRN)
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
