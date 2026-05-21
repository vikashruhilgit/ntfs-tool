import XCTest
@testable import NTFSCore

/// Tests for the pure MFT-sweep classifier (`MFTConsistency`) that teaches
/// `verify` / `reclaim-orphans` about extension MFT records. The classifier is
/// disk-I/O-free, so these tests construct `InUseRecordSummary` values directly
/// — no fixture image needed (and none possible, since the on-disk record
/// builder only produces base records).
final class MFTConsistencyTests: XCTestCase {

    /// The headline scenario: one reachable base, one legitimate extension
    /// (base IS in use), one leaked extension (base is NOT in use), and one
    /// true orphan base (in use, not reachable). The classifier must keep
    /// extensions out of the orphan set entirely.
    func testClassifiesBasesExtensionsAndOrphans() {
        let records: [InUseRecordSummary] = [
            // recnum 16: reachable base record.
            InUseRecordSummary(recordNumber: 16, isBaseRecord: true, baseRecordNumber: nil),
            // recnum 17: legitimate extension — its base (16) is an in-use base.
            InUseRecordSummary(recordNumber: 17, isBaseRecord: false, baseRecordNumber: 16),
            // recnum 18: leaked extension — its base (99) is NOT in use.
            InUseRecordSummary(recordNumber: 18, isBaseRecord: false, baseRecordNumber: 99),
            // recnum 20: true orphan base — in use but NOT reachable from $I30.
            InUseRecordSummary(recordNumber: 20, isBaseRecord: true, baseRecordNumber: nil),
        ]
        // Reachable from root's $I30: record 5 (root itself) and base 16.
        let reachable: Set<UInt64> = [5, 16]

        let result = MFTConsistency.classifyInUseRecords(records, reachable: reachable)

        XCTAssertEqual(result.baseRecords, [16, 20],
                       "only the two isBaseRecord records are bases")
        XCTAssertEqual(result.orphanBaseRecords, [20],
                       "the unreachable base is the only orphan; extensions never count")
        XCTAssertEqual(result.legitimateExtensions, [17],
                       "extension whose base is in-use is legitimate")
        XCTAssertEqual(result.leakedExtensions, [18],
                       "extension whose base is gone is leaked")
    }

    /// `baseRecordNumber(fromBaseFileReference:)` must mask off the high 16-bit
    /// sequence number and return only the low 48-bit record number.
    func testBaseRecordNumberStripsSequenceNumber() {
        // Packed reference: sequence 3 in the high 16 bits, recnum 16 low.
        let packed = (UInt64(3) << 48) | 16
        XCTAssertEqual(
            MFTConsistency.baseRecordNumber(fromBaseFileReference: packed), 16,
            "must extract the record number, discarding the sequence number"
        )
    }

    /// A legitimate extension is never an orphan even when its base record is
    /// itself unreachable/orphaned: the extension belongs to the base, and the
    /// base (orphan or not) is the unit `reclaim-orphans` acts on — not the
    /// extension. Guards against accidentally freeing an extension via its base.
    func testExtensionOfOrphanBaseIsNeverItselfAnOrphan() {
        let records: [InUseRecordSummary] = [
            InUseRecordSummary(recordNumber: 30, isBaseRecord: true, baseRecordNumber: nil),
            InUseRecordSummary(recordNumber: 31, isBaseRecord: false, baseRecordNumber: 30),
        ]
        // Neither is reachable from root.
        let result = MFTConsistency.classifyInUseRecords(records, reachable: [5])

        XCTAssertEqual(result.orphanBaseRecords, [30], "the base is an orphan")
        XCTAssertEqual(result.legitimateExtensions, [31],
                       "its extension is legitimate (base in use), never an orphan")
        XCTAssertTrue(result.orphanBaseRecords.isDisjoint(with: result.legitimateExtensions),
                      "no extension may ever appear in the orphan set")
    }
}
