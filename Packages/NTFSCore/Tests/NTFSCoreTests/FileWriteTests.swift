import XCTest
@testable import NTFSCore

/// Stage 4: Volume.write + Volume.truncate round-trips on the mutable fixture.
final class FileWriteTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/'")
        }
        return sub.recordNumber
    }

    func testWriteSmallStaysResidentAndReadsBack() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let recordNumber = try await volume.createFile(named: "small-resident.txt", inDirectory: parentRN)
        let payload = Data("Hello, write API.\n".utf8)
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)

        // Re-open via fresh BlockDevice — proves the data hit disk.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let readBack = try await reopenedVolume.readFile(at: recordNumber)
        XCTAssertEqual(readBack, payload)

        // Resident: $DATA should still be resident since payload is small.
        let mft = await reopenedVolume.mft()
        let attrs = try (try await mft.record(at: recordNumber)).attributes()
        let dataAttr = attrs.first { $0.type == .data }!
        guard case .resident = dataAttr.value else {
            return XCTFail("$DATA should still be resident for small payload")
        }
    }

    func testWriteLargePromotesToNonResidentAndReadsBack() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let recordNumber = try await volume.createFile(named: "large-non-resident.bin", inDirectory: parentRN)
        // 3000 bytes — well over the 700-byte resident threshold.
        let payload = Data(repeating: 0x5A, count: 3000)
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let readBack = try await reopenedVolume.readFile(at: recordNumber)
        XCTAssertEqual(readBack.count, payload.count)
        XCTAssertEqual(readBack, payload)

        // Verify it's non-resident.
        let mft = await reopenedVolume.mft()
        let attrs = try (try await mft.record(at: recordNumber)).attributes()
        let dataAttr = attrs.first { $0.type == .data }!
        guard case let .nonResident(_, _, _, _, _, realSize, _, extents) = dataAttr.value else {
            return XCTFail("$DATA should be non-resident for large payload")
        }
        XCTAssertEqual(realSize, UInt64(payload.count))
        XCTAssertFalse(extents.isEmpty)
    }

    func testAppendExtendsExistingNonResidentFile() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let recordNumber = try await volume.createFile(named: "append.bin", inDirectory: parentRN)
        let first = Data(repeating: 0xAA, count: 2000)
        let second = Data(repeating: 0xBB, count: 2000)
        try await volume.write(at: recordNumber, offset: 0, bytes: first)
        try await volume.write(at: recordNumber, offset: UInt64(first.count), bytes: second)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let readBack = try await reopenedVolume.readFile(at: recordNumber)
        XCTAssertEqual(readBack, first + second)
    }

    func testTruncateToZeroFreesClusters() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let beforeStats = try await volume.allocationStats()

        let recordNumber = try await volume.createFile(named: "to-truncate.bin", inDirectory: parentRN)
        let payload = Data(repeating: 0xCC, count: 8192)  // 2 clusters
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)
        let afterWriteStats = try await volume.allocationStats()
        XCTAssertEqual(afterWriteStats.freeClusters, beforeStats.freeClusters - 2)

        try await volume.truncate(at: recordNumber, newSize: 0)
        let afterTruncStats = try await volume.allocationStats()
        XCTAssertEqual(afterTruncStats.freeClusters, beforeStats.freeClusters,
                       "truncate to 0 should free all clusters back")

        // Read-back must be empty.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let readBack = try await reopenedVolume.readFile(at: recordNumber)
        XCTAssertEqual(readBack.count, 0)
    }

    func testTruncateShrinkAtClusterBoundary() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let recordNumber = try await volume.createFile(named: "shrink.bin", inDirectory: parentRN)
        // 4 clusters worth.
        let payload = Data(repeating: 0xDD, count: 16384)
        try await volume.write(at: recordNumber, offset: 0, bytes: payload)
        let preStats = try await volume.allocationStats()

        // Shrink to 2 clusters → free 2.
        try await volume.truncate(at: recordNumber, newSize: 8192)
        let postStats = try await volume.allocationStats()
        XCTAssertEqual(postStats.freeClusters, preStats.freeClusters + 2)

        // Read-back is now 8192 bytes.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopenedVolume = try await Volume(device: reader)
        let readBack = try await reopenedVolume.readFile(at: recordNumber)
        XCTAssertEqual(readBack.count, 8192)
        XCTAssertEqual(readBack, payload.prefix(8192))
    }
}
