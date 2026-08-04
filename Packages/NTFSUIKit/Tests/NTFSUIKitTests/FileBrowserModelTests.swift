import XCTest
import NTFSOps
@testable import NTFSUIKit

/// Guards on the browser's decision logic — the parts that decide whether a
/// destructive action is allowed. The NTFS work itself is the engine's, covered
/// by the NTFSOps and ntfsctl suites.
@MainActor
final class FileBrowserModelTests: XCTestCase {

    func testDirectoriesSortBeforeFilesThenCaseInsensitively() {
        let rows = [
            entry(1, "zebra.txt", dir: false),
            entry(2, "Apple", dir: true),
            entry(3, "alpha.txt", dir: false),
            entry(4, "beta", dir: true)
        ].sorted(by: BrowserEntry.displayOrder)

        XCTAssertEqual(rows.map(\.name), ["Apple", "beta", "alpha.txt", "zebra.txt"])
    }

    func testPasteIsBlockedOnAReadOnlyVolume() {
        let model = FileBrowserModel(devicePath: "/dev/null")
        // Never opened → not writable. Every mutating path must refuse.
        XCTAssertNotNil(model.pasteBlockedReason())
        XCTAssertEqual(model.pasteBlockedReason(), "This volume is open read-only.")
    }

    func testTimeRemainingWordingIsCoarse() {
        // Second-level precision on a long copy reads as false precision.
        XCTAssertEqual(FileBrowserModel.timeRemaining(12), "less than a minute")
        XCTAssertEqual(FileBrowserModel.timeRemaining(59), "less than a minute")
        XCTAssertEqual(FileBrowserModel.timeRemaining(60), "1 minute")
        XCTAssertEqual(FileBrowserModel.timeRemaining(150), "3 minutes")
        XCTAssertEqual(FileBrowserModel.timeRemaining(5400), "1.5 hours")
    }

    func testDetailLineOmitsETAWhenThereIsNoSignal() {
        // A just-started copy has no rate yet; showing "about 0 seconds left"
        // would be worse than showing nothing.
        let fresh = TransferProgress(
            filesDone: 0, totalFiles: 10,
            bytesDone: 0, totalBytes: 1000,
            currentName: "a", startedAt: Date()
        )
        let line = FileBrowserModel.detailLine(fresh)
        XCTAssertTrue(line.contains("0 of 10"))
        XCTAssertFalse(line.contains("left"))
    }

    func testSkippedItemsAreReportedAfterAnOperation() {
        var summary = TransferSummary()
        summary.skippedFiles = 3
        XCTAssertEqual(FileBrowserModel.note(for: summary, cancelled: false), "3 items skipped")

        summary.skippedFiles = 1
        XCTAssertEqual(FileBrowserModel.note(for: summary, cancelled: false), "1 item skipped")

        // A clean run should say nothing rather than "0 items skipped".
        summary.skippedFiles = 0
        XCTAssertNil(FileBrowserModel.note(for: summary, cancelled: false))
    }

    func testPermissionErrorsExplainTheRootOwnedDevice() {
        // A bare POSIX code leaves the user with nothing to act on; this is the
        // single most likely failure on a real drive, so it gets real wording.
        struct Denied: Error, CustomStringConvertible {
            var description: String { "open /dev/disk6s1 failed: Permission denied" }
        }
        let text = FileBrowserModel.message(for: Denied())
        XCTAssertTrue(text.contains("administrator"))
        XCTAssertTrue(text.contains("device"))
    }

    private func entry(_ rn: UInt64, _ name: String, dir: Bool) -> BrowserEntry {
        BrowserEntry(recordNumber: rn, name: name, isDirectory: dir, size: 0, modified: nil)
    }
}
