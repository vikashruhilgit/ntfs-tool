import XCTest
@testable import NTFSCore

/// Tests covering the post-v0.1 capability gaps:
///  - Streaming `writeFile` (no 1 GiB cap, chunked memory profile).
///  - Bulk insert into LARGE_INDEX directories ($I30 B-tree descent).
///  - `Volume.resolvePath` path → MFT-recnum helper.
final class StreamingAndLargeIndexTests: XCTestCase {

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

    // MARK: - Streaming writeFile

    func testStreamingWriteFileRoundTripsLargePayload() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "stream.bin", inDirectory: parentRN)

        // Build a 256 KiB payload of deterministic bytes (cluster size 4096 → 64 clusters).
        let size = 256 * 1024
        var expected = Data(count: size)
        for i in 0..<size {
            expected[i] = UInt8((i * 31) & 0xFF)
        }
        // Feed in 7000-byte chunks so the chunk boundaries don't line up with
        // cluster boundaries — exercises the cross-extent slicing.
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(size)) {
            if cursor >= size { return Data() }
            let take = min(7000, size - cursor)
            let chunk = expected.subdata(in: cursor..<(cursor + take))
            cursor += take
            return chunk
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack.count, size, "read-back length mismatch")
        XCTAssertEqual(readBack, expected, "read-back bytes diverge from written")
    }

    func testStreamingWriteFileSmallStaysResident() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "tiny.txt", inDirectory: parentRN)

        // Below residentDataThreshold (~700 bytes) — gathers in memory and
        // writes resident $DATA.
        let payload = Data("streaming-but-small\n".utf8)
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(payload.count)) {
            if cursor >= payload.count { return Data() }
            let chunk = payload.subdata(in: cursor..<payload.count)
            cursor = payload.count
            return chunk
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack, payload)
    }

    func testStreamingWriteFileFromHostFile() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "from-host.bin", inDirectory: parentRN)

        // Drop a 64 KiB host file, write it via the file-path convenience.
        let hostPath = FileManager.default.temporaryDirectory.appendingPathComponent("ntfs-stream-test-\(UUID().uuidString).bin")
        var hostBytes = Data(count: 64 * 1024)
        for i in 0..<hostBytes.count { hostBytes[i] = UInt8((i * 7) & 0xFF) }
        try hostBytes.write(to: hostPath)
        addTeardownBlock { try? FileManager.default.removeItem(at: hostPath) }

        try await volume.writeFile(at: rn, fromFileAt: hostPath, chunkSize: 4096)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack, hostBytes)
    }

    func testStreamingReadFileSliceFollowsWrite() async throws {
        // readFileSlice has no 1 GiB cap; verify it round-trips chunked
        // streaming reads of the written content.
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "sliced.bin", inDirectory: parentRN)

        let size = 32 * 1024
        var expected = Data(count: size)
        for i in 0..<size { expected[i] = UInt8(i & 0xFF) }
        try await volume.write(at: rn, offset: 0, bytes: expected)

        // Stream-read in 1 KiB slices.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        var assembled = Data()
        var offset: UInt64 = 0
        while assembled.count < size {
            let chunk = try await reopened.readFileSlice(at: rn, offset: offset, length: 1024)
            if chunk.isEmpty { break }
            assembled.append(chunk)
            offset += UInt64(chunk.count)
        }
        XCTAssertEqual(assembled, expected, "streaming readFileSlice should reassemble the full file")
    }

    // MARK: - LARGE_INDEX bulk insert

    func testBulkInsertIntoLargeIndexRoot() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // The fixture root is LARGE_INDEX (15 entries — too many for resident
        // $INDEX_ROOT). Insert N new files; each should land in some leaf INDX
        // block via B-tree descent. N=20 fits comfortably below the
        // single-leaf-full ceiling on this fixture's 4 KiB INDX block; the
        // explicit leaf-full assertion lives in its own test below.
        var createdRecnums: [UInt64] = []
        var createdNames: [String] = []
        for i in 0..<20 {
            let name = String(format: "bulk-%04d.txt", i)
            let rn = try await volume.createFile(named: name, inDirectory: 5)
            createdRecnums.append(rn)
            createdNames.append(name)
        }
        XCTAssertEqual(Set(createdRecnums).count, 20, "each insert should get a distinct MFT slot")

        // Re-open and enumerate — every inserted name should appear exactly once.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })
        for name in createdNames {
            XCTAssertTrue(names.contains(name), "inserted '\(name)' missing from re-read enumeration")
        }
    }

    /// v1 limit: a single fully-packed leaf rejects further inserts with
    /// `unsupportedFeature` (leaf split is future work). This test documents
    /// the threshold so a future split implementation has a regression target.
    func testLargeIndexLeafFullReportsUnsupportedFeature() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        var inserted = 0
        var sawLeafFull = false
        for i in 0..<200 {
            do {
                _ = try await volume.createFile(named: String(format: "fill-%04d.txt", i), inDirectory: 5)
                inserted += 1
            } catch NTFSError.unsupportedFeature(let desc) where desc.contains("leaf full") {
                sawLeafFull = true
                break
            }
        }
        XCTAssertTrue(sawLeafFull, "expected to hit 'leaf full' after \(inserted) inserts")
        XCTAssertGreaterThan(inserted, 10, "should accept at least 10 inserts before saturating the only leaf")
    }

    func testLargeIndexInsertSurvivesDeleteRoundTrip() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        var rns: [UInt64] = []
        for i in 0..<10 {
            let name = "rt-\(i).bin"
            let rn = try await volume.createFile(named: name, inDirectory: 5)
            rns.append(rn)
        }
        for rn in rns {
            try await volume.deleteFile(at: rn)
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })
        for i in 0..<10 {
            XCTAssertFalse(names.contains("rt-\(i).bin"), "deleted entry rt-\(i).bin still present in enumeration")
        }
    }

    // MARK: - Path resolution

    func testResolvePathRoot() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let rootRN1 = try await volume.resolvePath("/")
        let rootRN2 = try await volume.resolvePath("")
        let rootRN3 = try await volume.resolvePath(".")
        XCTAssertEqual(rootRN1, 5)
        XCTAssertEqual(rootRN2, 5)
        XCTAssertEqual(rootRN3, 5)
    }

    func testResolvePathOneLevel() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // 'sub' is the always-resident subdir in the fixture.
        let resolved = try await volume.resolvePath("/sub")
        XCTAssertNotNil(resolved)
        let subRN = try await subDirRecordNumber(volume: volume)
        XCTAssertEqual(resolved, subRN)
    }

    func testResolvePathMissing() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let missing = try await volume.resolvePath("/no-such-thing-exists")
        XCTAssertNil(missing)
    }

    func testResolvePathTwoLevels() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // 'sub/nested.txt' is the always-present nested file in the fixture.
        let resolved = try await volume.resolvePath("/sub/nested.txt")
        XCTAssertNotNil(resolved, "should resolve nested fixture file")
    }
}
