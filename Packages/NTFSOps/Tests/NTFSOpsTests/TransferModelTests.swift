import XCTest
@testable import NTFSOps

/// Pure-value tests for the transfer model. The engine itself is exercised
/// against real `.img` fixtures by the NTFSCore and ntfsctl suites, which drive
/// it through `ntfsctl cp`.
final class TransferModelTests: XCTestCase {

    func testProgressFractionIsBoundedAndSafeAtZeroTotal() {
        // A zero-byte total must report complete, not NaN — a NaN reaches
        // SwiftUI's ProgressView and renders an empty bar forever.
        let empty = makeProgress(bytesDone: 0, totalBytes: 0)
        XCTAssertEqual(empty.fraction, 1.0)

        let half = makeProgress(bytesDone: 50, totalBytes: 100)
        XCTAssertEqual(half.fraction, 0.5, accuracy: 0.0001)

        // Totals are an estimate from a pre-scan; a file that grew between the
        // scan and the copy must not push the bar past full.
        let over = makeProgress(bytesDone: 150, totalBytes: 100)
        XCTAssertEqual(over.fraction, 1.0)
    }

    func testEstimatedTimeRemainingIsNilWithoutSignal() {
        // Nothing left to do — no estimate rather than zero.
        let done = makeProgress(bytesDone: 100, totalBytes: 100, startedAt: Date(timeIntervalSinceNow: -10))
        XCTAssertNil(done.estimatedSecondsRemaining)

        // Rate established, work remaining → a finite estimate.
        let running = makeProgress(bytesDone: 50, totalBytes: 100, startedAt: Date(timeIntervalSinceNow: -10))
        let eta = try? XCTUnwrap(running.estimatedSecondsRemaining)
        XCTAssertNotNil(eta)
    }

    func testHumanBytesUnitBoundaries() {
        XCTAssertEqual(ByteFormat.human(0), "0 B")
        XCTAssertEqual(ByteFormat.human(1023), "1023 B")
        XCTAssertEqual(ByteFormat.human(1024), "1.0 KiB")
        XCTAssertEqual(ByteFormat.human(1024 * 1024), "1.0 MiB")
        XCTAssertEqual(ByteFormat.human(1024 * 1024 * 1024), "1.00 GiB")
    }

    func testFreeSpaceErrorNamesBothNumbers() {
        // The message has to say what was needed AND what was available —
        // "not enough space" alone leaves the user with nothing to act on.
        let err = TransferError.insufficientFreeSpace(
            requiredBytes: 5 * 1024 * 1024 * 1024,
            freeBytes: 1024 * 1024 * 1024,
            files: 42
        )
        let text = try? XCTUnwrap(err.errorDescription)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("5.00 GiB"))
        XCTAssertTrue(text!.contains("1.00 GiB"))
        XCTAssertTrue(text!.contains("42"))
    }

    func testDefaultOptionsMatchTheCLIDefaults() {
        // The GUI inherits these defaults; if they drift from `ntfsctl cp` the
        // two front-ends silently behave differently on conflicts.
        let opts = TransferOptions()
        XCTAssertEqual(opts.conflict, .replace)
        XCTAssertFalse(opts.removeSource)
        XCTAssertEqual(opts.chunkSize, 1 << 20)
    }

    private func makeProgress(
        bytesDone: UInt64,
        totalBytes: UInt64,
        startedAt: Date = Date()
    ) -> TransferProgress {
        TransferProgress(
            filesDone: 1,
            totalFiles: 1,
            bytesDone: bytesDone,
            totalBytes: totalBytes,
            currentName: "f",
            startedAt: startedAt
        )
    }
}
