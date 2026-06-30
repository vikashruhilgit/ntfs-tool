import XCTest
@testable import NTFSUIKit

/// Drives the format/repair state machine in `VolumeDetailLoader` through its
/// injection seams (`formatProvider` / `repairProvider`) so no real device is
/// touched. Covers idle→loading→loaded/failed and the three repair outcomes.
@MainActor
final class FormatRepairLoaderTests: XCTestCase {

    private func loader(
        format: (@Sendable (String) async throws -> FormatResult)? = nil,
        repair: (@Sendable () async throws -> RepairResult)? = nil
    ) -> VolumeDetailLoader {
        VolumeDetailLoader(
            devicePath: "/dev/disk9s1",
            label: "TESTVOL",
            isWritable: true,
            // Provide facts so the post-action `load()` refresh succeeds without
            // a real device.
            factsProvider: {
                VolumeFacts(
                    label: "TESTVOL", devicePath: "/dev/disk9s1",
                    totalBytes: 64 * 1024 * 1024, freeBytes: 60 * 1024 * 1024,
                    usedBytes: 4 * 1024 * 1024, bytesPerCluster: 4096,
                    mftByteOffset: 0, mftCluster: 0, isDirty: false,
                    ntfsMajorVersion: 3, ntfsMinorVersion: 1, isWritable: true
                )
            },
            formatProvider: format,
            repairProvider: repair
        )
    }

    // MARK: - Format

    func testFormatSuccessTransitionsToLoaded() async {
        let l = loader(format: { label in FormatResult(label: label, devicePath: "/dev/disk9s1") })
        XCTAssertEqual(l.format, .idle)
        await l.runFormat(label: "NEWLABEL")
        XCTAssertNotNil(l.format.value)
        XCTAssertEqual(l.format.value?.label, "NEWLABEL")
        // Post-format refresh repopulated the info state.
        XCTAssertNotNil(l.info.value)
    }

    func testFormatFailureSurfacesMessage() async {
        struct Boom: Error {}
        let l = loader(format: { _ in throw Boom() })
        await l.runFormat(label: "X")
        XCTAssertNotNil(l.format.errorMessage)
        XCTAssertNil(l.format.value)
    }

    // MARK: - Repair outcomes

    func testRepairCleanOutcome() async {
        let l = loader(repair: { RepairResult(outcome: .clean, problems: []) })
        await l.runRepair()
        XCTAssertEqual(l.repair.value?.outcome, .clean)
        XCTAssertTrue(l.repair.value?.isResolved ?? false)
    }

    func testRepairClearedDirtyOutcome() async {
        let l = loader(repair: { RepairResult(outcome: .clearedDirty, problems: []) })
        await l.runRepair()
        XCTAssertEqual(l.repair.value?.outcome, .clearedDirty)
        XCTAssertTrue(l.repair.value?.isResolved ?? false)
        XCTAssertTrue(l.repair.value?.headline.lowercased().contains("dirty") ?? false)
    }

    func testRepairProblemsFoundAdvisesChkdsk() async {
        let l = loader(repair: {
            RepairResult(outcome: .problemsFound, problems: ["2 cluster(s) double-allocated."])
        })
        await l.runRepair()
        XCTAssertEqual(l.repair.value?.outcome, .problemsFound)
        XCTAssertFalse(l.repair.value?.isResolved ?? true)
        XCTAssertTrue(l.repair.value?.summary.lowercased().contains("chkdsk") ?? false)
        XCTAssertEqual(l.repair.value?.problems.count, 1)
    }

    func testRepairFailureSurfacesMessage() async {
        struct Boom: Error {}
        let l = loader(repair: { throw Boom() })
        await l.runRepair()
        XCTAssertNotNil(l.repair.errorMessage)
    }

    // MARK: - DangerButtonStyle exists and is constructible

    func testDangerButtonStyleConstructs() {
        _ = DangerButtonStyle()
    }
}
