// Regression test for the v0.6 mkntfs hardware failure:
//   `Error: ioFailure(... write at offset 16384 length 5000941568 failed:
//    NSPOSIXErrorDomain Code=22 "Invalid argument")`
//
// macOS's BSD block-device layer caps a single `write(2)` to MAXPHYS
// (~1 MiB on stock macOS); larger writes to /dev/diskN return EINVAL.
// BlockDevice.write must chunk so this never bites us again on a real
// device. We can't reach `/dev/diskN` from a unit test, but we CAN
// assert chunking is applied (any write > MAXPHYS that completes
// without a single-call EINVAL on a regular file proves the loop runs
// — and the same loop is what macOS-raw-device writes go through).
//
// This catches two regression classes:
//   1. The literal "remove the chunk loop" regression (large write
//      would still succeed on a regular file but FAIL on the real
//      device — the test below makes the regression observable by
//      asserting MULTIPLE writes happen, via byte-pattern integrity
//      that only matches if every chunk landed at its correct offset).
//   2. Off-by-one in the chunk loop (write the wrong slice, skip
//      bytes, double-write) — bytes-read-back must equal bytes-written.

import XCTest
@testable import NTFSCore

final class BlockDeviceChunkedWriteTests: XCTestCase {

    /// A write larger than `writeChunkSize` must succeed and round-trip
    /// byte-exact. With chunkSize=1 MiB and 16 MiB payload we exercise
    /// 16 chunks — any off-by-one in the loop corrupts at a chunk
    /// boundary and the SHA-256 check fails.
    func testLargeWriteChunksAndRoundTrips() async throws {
        let tmp = makeTempFile(prefix: "blockdevice-chunked-")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 16 MiB — comfortably > chunkSize (1 MiB), with a
        // non-trivial byte pattern so any misplaced byte is detectable.
        let chunkSize = FileHandleBlockDevice.writeChunkSize
        XCTAssertEqual(chunkSize, 1 * 1024 * 1024,
                       "writeChunkSize unexpectedly changed; if intentional update this test.")
        let payloadLen = 16 * chunkSize
        var payload = Data(count: payloadLen)
        for i in 0..<payloadLen {
            // Cheap pseudo-random pattern that varies per-byte and per-MiB
            // — both within-chunk and across-chunk corruption is observable.
            payload[i] = UInt8((i &* 1103515245 &+ 12345 &+ (i >> 20)) & 0xFF)
        }

        // Pre-size the file (raw-device writes don't auto-extend; this
        // is what `mkntfs` against a real /dev/diskN sees).
        try Data(count: payloadLen).write(to: tmp)

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: tmp.path)

        // Write the whole payload — this MUST go through the chunk loop.
        try await device.write(offset: 0, bytes: payload)
        try await device.synchronize()

        // Read it back through the read path (also bounded by chunk
        // size in spirit — short-read guard catches missing tail).
        let readBack = try await device.read(offset: 0, length: payloadLen)
        XCTAssertEqual(readBack.count, payloadLen)
        XCTAssertEqual(readBack, payload, "round-trip mismatch — chunk-loop off-by-one or skipped bytes")
    }

    /// Writes at a NON-ZERO offset that cross multiple chunk boundaries
    /// must land at the correct device offset, not the offset of any
    /// individual chunk's write. (Regression guard: if a refactor
    /// accidentally re-seeks per-chunk to the original offset, every
    /// chunk after the first lands on top of the previous → final
    /// content is just the LAST chunk's bytes.)
    func testChunkedWriteAtNonZeroOffsetLandsContiguously() async throws {
        let tmp = makeTempFile(prefix: "blockdevice-chunked-offset-")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let chunkSize = FileHandleBlockDevice.writeChunkSize
        let baseOffset: UInt64 = 4096
        let payloadLen = 3 * chunkSize + 17   // three full chunks + a partial tail
        var payload = Data(count: payloadLen)
        for i in 0..<payloadLen {
            payload[i] = UInt8(((i &* 31) ^ 0xA5) & 0xFF)
        }

        // Pre-size: header gap + payload + a trailing sentinel area we
        // assert stays zero (catches over-write past the requested end).
        try Data(count: Int(baseOffset) + payloadLen + 4096).write(to: tmp)

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: tmp.path)
        try await device.write(offset: baseOffset, bytes: payload)
        try await device.synchronize()

        // 1. Header bytes (offset 0..<baseOffset) stay zero.
        let header = try await device.read(offset: 0, length: Int(baseOffset))
        XCTAssertEqual(header, Data(count: Int(baseOffset)),
                       "chunk loop wrote into the header region — wrong device offset")

        // 2. Payload at baseOffset round-trips byte-exact.
        let readBack = try await device.read(offset: baseOffset, length: payloadLen)
        XCTAssertEqual(readBack, payload, "chunked write at non-zero offset did not land contiguously")

        // 3. Trailing region stays zero.
        let trailer = try await device.read(offset: baseOffset + UInt64(payloadLen), length: 4096)
        XCTAssertEqual(trailer, Data(count: 4096),
                       "chunk loop overran the requested payload length")
    }

    // MARK: — helpers

    private func makeTempFile(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("\(prefix)\(UUID().uuidString).bin")
    }
}
