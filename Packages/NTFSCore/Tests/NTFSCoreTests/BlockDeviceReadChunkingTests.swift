import XCTest
@testable import NTFSCore

/// Validates `FileHandleBlockDevice.read` returns byte-exact data for reads
/// LARGER than the 1 MiB chunk size — the path that broke `verify --deep` /
/// `cp` on a real 4 TB drive (the 122 MB `$Bitmap` read), and the path whose
/// correctness determines whether a "free-but-referenced" finding is real
/// corruption or a read artifact.
final class BlockDeviceReadChunkingTests: XCTestCase {

    /// Deterministic pseudo-random byte for position `i` — a pattern that
    /// changes every byte so any mis-stitched chunk boundary corrupts the
    /// comparison.
    private func patternByte(_ i: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (i &* 2_654_435_761) ^ (i >> 13) ^ (i &* 40_503))
    }

    private func makeTempFile(byteCount: Int) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-chunk-\(UUID().uuidString).bin").path
        var data = Data(count: byteCount)
        for i in 0..<byteCount { data[i] = patternByte(i) }
        try data.write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testLargeReadIsByteExactAcrossChunkBoundaries() async throws {
        // 5 MiB + a non-chunk-multiple tail so the last chunk is partial.
        let total = 5 * 1024 * 1024 + 12345
        let path = try makeTempFile(byteCount: total)
        let dev = try FileHandleBlockDevice(openingFileAt: path)

        // (1) One read spanning the whole file (5 chunk boundaries).
        let whole = try await dev.read(offset: 0, length: total)
        XCTAssertEqual(whole.count, total)
        for i in stride(from: 0, to: total, by: 7919) {   // sample at a prime stride
            XCTAssertEqual(whole[i], patternByte(i), "mismatch at byte \(i)")
        }
        XCTAssertEqual(whole[total - 1], patternByte(total - 1), "last byte wrong")

        // (2) A read that STARTS mid-file and crosses several chunk boundaries —
        // catches any offset/position drift in the chunk loop.
        let off = 1_000_003
        let len = 3 * 1024 * 1024 + 777
        let mid = try await dev.read(offset: UInt64(off), length: len)
        XCTAssertEqual(mid.count, len)
        for j in stride(from: 0, to: len, by: 6131) {
            XCTAssertEqual(mid[mid.startIndex + j], patternByte(off + j), "mid-read mismatch at +\(j)")
        }
        XCTAssertEqual(mid[mid.startIndex + len - 1], patternByte(off + len - 1))

        // (3) Exactly on the chunk boundary (1 MiB) and one past it.
        let atBoundary = try await dev.read(offset: UInt64(1024 * 1024 - 3), length: 6)
        for k in 0..<6 {
            XCTAssertEqual(atBoundary[atBoundary.startIndex + k], patternByte(1024 * 1024 - 3 + k))
        }
    }

    /// A sub-sector write to a raw device must read-modify-write the enclosing
    /// block(s) and change ONLY the requested bytes — clobbering neighbours
    /// would silently corrupt adjacent on-disk structures (this is exactly the
    /// 8-byte `$MFT $BITMAP` write that hit EINVAL on the real drive).
    func testSubSectorWriteDoesNotClobberNeighbours() async throws {
        let total = 4096
        let path = try makeTempFile(byteCount: total)
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        await dev._forceBlockSizeForTesting(512)   // pretend it's a 512-byte raw device

        // Overwrite 8 bytes at a NON-block-aligned offset that also has a
        // non-aligned length — forces the read-modify-write path.
        let patch = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        try await dev.write(offset: 1000, bytes: patch)

        // Read the whole file back and verify: patched bytes changed, every
        // other byte still holds its original pattern.
        await dev._forceBlockSizeForTesting(nil)   // read back as a plain file
        let after = try await dev.read(offset: 0, length: total)
        for i in 0..<total {
            let expected: UInt8 = (i >= 1000 && i < 1008) ? patch[i - 1000] : patternByte(i)
            XCTAssertEqual(after[i], expected, "byte \(i) wrong after sub-sector write")
        }
    }

    func testReadPastEndThrowsShortRead() async throws {
        let total = 2 * 1024 * 1024
        let path = try makeTempFile(byteCount: total)
        let dev = try FileHandleBlockDevice(openingFileAt: path)
        do {
            _ = try await dev.read(offset: UInt64(total - 100), length: 4096)
            XCTFail("expected shortRead past EOF")
        } catch NTFSError.shortRead {
            // expected
        }
    }
}
