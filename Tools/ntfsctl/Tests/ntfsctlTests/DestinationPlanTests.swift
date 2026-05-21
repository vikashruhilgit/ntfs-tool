import XCTest
@testable import ntfsctl

/// Pure decision-matrix tests for `DestinationPlan.resolve`. No fixtures, no
/// I/O — these exercise every NEW / NEST / MERGE branch plus the conflict
/// policy and the destination-is-a-file error case. They are the fast,
/// deterministic counterpart to the end-to-end merge test in
/// `CpMergeIntegrationTests`.
final class DestinationPlanTests: XCTestCase {

    // (a) dest absent → .new (regardless of -T / -n / source kind).
    func testDestinationAbsentIsNew() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: false,
            destIsDirectory: false,
            sourceIsDirectory: true,
            noTargetDirectory: true,
            noClobber: false
        )
        XCTAssertEqual(outcome, .new)
    }

    // (b) dest exists as dir, no -T → .nest (POSIX-standard nesting).
    func testExistingDirWithoutNoTargetDirectoryNests() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: true,
            destIsDirectory: true,
            sourceIsDirectory: true,
            noTargetDirectory: false,
            noClobber: false
        )
        XCTAssertEqual(outcome, .nest)
    }

    // (c) dest exists as dir, -T, dir source → .merge (default conflict).
    func testExistingDirWithNoTargetDirectoryAndDirSourceMerges() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: true,
            destIsDirectory: true,
            sourceIsDirectory: true,
            noTargetDirectory: true,
            noClobber: false
        )
        XCTAssertEqual(outcome, .merge(conflict: .replace))
    }

    // (d) .merge + --no-clobber → .merge(conflict: .skip).
    func testMergeWithNoClobberSkips() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: true,
            destIsDirectory: true,
            sourceIsDirectory: true,
            noTargetDirectory: true,
            noClobber: true
        )
        XCTAssertEqual(outcome, .merge(conflict: .skip))
    }

    // (e) .merge + default (no --no-clobber) → .merge(conflict: .replace).
    func testMergeWithoutNoClobberReplaces() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: true,
            destIsDirectory: true,
            sourceIsDirectory: true,
            noTargetDirectory: true,
            noClobber: false
        )
        XCTAssertEqual(outcome, .merge(conflict: .replace))
    }

    // dest exists as a FILE → throws DestinationPlanError.destinationIsFile.
    func testExistingFileThrows() {
        XCTAssertThrowsError(
            try DestinationPlan.resolve(
                destExists: true,
                destIsDirectory: false,
                sourceIsDirectory: true,
                noTargetDirectory: false,
                noClobber: false
            )
        ) { error in
            XCTAssertEqual(error as? DestinationPlanError, .destinationIsFile)
        }
    }

    // dest exists as a FILE still throws even with -T (file check precedes
    // the merge decision).
    func testExistingFileThrowsEvenWithNoTargetDirectory() {
        XCTAssertThrowsError(
            try DestinationPlan.resolve(
                destExists: true,
                destIsDirectory: false,
                sourceIsDirectory: true,
                noTargetDirectory: true,
                noClobber: false
            )
        ) { error in
            XCTAssertEqual(error as? DestinationPlanError, .destinationIsFile)
        }
    }

    // -T with a NON-dir source into an existing dir → .nest. The planner only
    // merges directory sources; a file source still nests under dest.
    func testNoTargetDirectoryWithFileSourceNests() throws {
        let outcome = try DestinationPlan.resolve(
            destExists: true,
            destIsDirectory: true,
            sourceIsDirectory: false,
            noTargetDirectory: true,
            noClobber: false
        )
        XCTAssertEqual(outcome, .nest)
    }
}
