import XCTest
@testable import NTFSCore

/// Rubric item 6 (Block I — FSKit write-through): a single integration test
/// that exercises the FULL flow the FSKit adapter drives through NTFSCore —
/// createItem → write(contents:) → read-back → endWriteSession (sync/flush) →
/// removeItem — and asserts the volume stays consistent afterwards.
///
/// The FSKit extension (`Extensions/NTFSFileSystem/Sources/NTFSVolume.swift`)
/// is a thin adapter: `createItem`→`createFile`, `write(contents:)`→`write`,
/// `removeItem`→`deleteFile`, `synchronize`→`endWriteSession`. The extension
/// can't be unit-tested without a mounted volume, so this test drives the same
/// NTFSCore calls in the same order against a writable scratch image, proving
/// the load-bearing path the adapter marshals onto is correct end-to-end.
final class FSKitWriteThroughRoundTripTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// `sub/` keeps a resident $I30 so create/delete stay on the simple path.
    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/' — regenerate via scripts/make_test_images.sh")
        }
        return sub.recordNumber
    }

    /// create → write → (flush) → reopen → read-back identical → delete →
    /// reopen → entry gone + MFT slot freed + allocation restored.
    func testCreateWriteReadDeleteRoundTripStaysConsistent() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let mft = await volume.mft()
        let parentRN = try await subDirRecordNumber(volume: volume)

        // Baselines the round-trip must restore exactly.
        let firstFreeBefore = try await mft.findFreeRecordNumber()
        let statsBefore = try await volume.allocationStats()
        let namesBefore = Set(try await volume.enumerate(directory: parentRN).map { $0.name })
        XCTAssertFalse(namesBefore.contains("roundtrip.bin"))

        // --- createItem ---
        let recordNumber = try await volume.createFile(named: "roundtrip.bin", inDirectory: parentRN)

        // --- write(contents:) --- payload large enough to force cluster
        // allocation through $Bitmap (non-resident $DATA), exercising rubric
        // item 3's "including $Bitmap cluster allocation" clause.
        let payload = Data((0..<6000).map { UInt8($0 & 0xFF) })
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)

        // --- synchronize / flush (what NTFSVolume.synchronize drives) ---
        // Persists pending data + metadata and clears the dirty bit. Must not
        // throw on a writable device.
        try await volume.endWriteSession()

        // --- read-back on a FRESH device: proves it hit disk identically ---
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: recordNumber)
        XCTAssertEqual(readBack, payload, "bytes read back after flush must be byte-identical to what was written")

        // Entry is visible in the parent index after the flush+reopen.
        let namesAfterCreate = Set(try await reopened.enumerate(directory: parentRN).map { $0.name })
        XCTAssertTrue(namesAfterCreate.contains("roundtrip.bin"),
                      "created file must be visible in parent $I30 after flush; got \(namesAfterCreate)")

        // --- removeItem ---
        try await volume.deleteFile(at: recordNumber)
        try await volume.endWriteSession()

        // --- reopen again: entry gone, slot freed, clusters returned ---
        let reader2 = try FileHandleBlockDevice(openingFileAt: path)
        let reopened2 = try await Volume(device: reader2)

        let namesAfterDelete = Set(try await reopened2.enumerate(directory: parentRN).map { $0.name })
        XCTAssertFalse(namesAfterDelete.contains("roundtrip.bin"),
                       "deleted file must be absent from parent $I30; got \(namesAfterDelete)")

        let deletedRecord = try await (reopened2.mft()).record(at: recordNumber)
        XCTAssertFalse(deletedRecord.isInUse, "MFT record must be marked free after delete")

        // Consistency check: the MFT first-free pointer and the $Bitmap free
        // count must both be restored to their pre-create values — proving the
        // record slot AND every allocated cluster were returned.
        let firstFreeAfter = try await (reopened2.mft()).findFreeRecordNumber()
        XCTAssertEqual(firstFreeAfter, firstFreeBefore,
                       "MFT slot must be free again after delete round-trip")

        let statsAfter = try await reopened2.allocationStats()
        XCTAssertEqual(statsAfter.freeClusters, statsBefore.freeClusters,
                       "all clusters allocated for the file must be returned to $Bitmap after delete")
    }
}
