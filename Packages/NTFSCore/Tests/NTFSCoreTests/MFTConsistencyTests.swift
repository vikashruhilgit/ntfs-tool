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

    // MARK: - splitLeakedExtensions: authoritative base-free split (v0.5)

    /// The reclaimable case: a leaked extension (recnum 18) whose base (99) was
    /// AUTHORITATIVELY read off disk and confirmed IN_USE=0. It's a dead
    /// extension — its slot + migrated clusters can be reclaimed.
    func testSplitLeakedExtensionsBaseConfirmedFreeIsReclaimable() {
        let records: [InUseRecordSummary] = [
            InUseRecordSummary(recordNumber: 18, isBaseRecord: false, baseRecordNumber: 99),
        ]
        let split = MFTConsistency.splitLeakedExtensions(
            records,
            leakedExtensions: [18],
            basesConfirmedFree: [99]
        )
        XCTAssertEqual(split.baseFreeExtensions, [18],
                       "extension whose base was confirmed free is reclaimable")
        XCTAssertEqual(split.baseUnresolvedExtensions, [],
                       "nothing is deferred when the base is confirmed free")
    }

    /// The conflation case (iii), AC-10: same leaked extension, but the base
    /// (99) was NOT confirmed free — it was IN_USE-but-unparseable, so the
    /// caller never added it to `basesConfirmedFree`. Default-deny: the
    /// extension must be deferred (could belong to a live file), NEVER freed.
    func testSplitLeakedExtensionsBaseNotConfirmedFreeIsDeferred() {
        let records: [InUseRecordSummary] = [
            InUseRecordSummary(recordNumber: 18, isBaseRecord: false, baseRecordNumber: 99),
        ]
        let split = MFTConsistency.splitLeakedExtensions(
            records,
            leakedExtensions: [18],
            basesConfirmedFree: []
        )
        XCTAssertEqual(split.baseFreeExtensions, [],
                       "no extension is reclaimable when its base wasn't confirmed free")
        XCTAssertEqual(split.baseUnresolvedExtensions, [18],
                       "an unconfirmed base defers the extension (could be a live file)")
    }

    /// Default-deny when the leaked extension has no summary in `records` at
    /// all (so its base recnum is unknown): it must be deferred, never freed.
    func testSplitLeakedExtensionsBaseAbsentFromRecordsIsDeferred() {
        // No summary describes recnum 18, yet it's in the leaked set.
        let records: [InUseRecordSummary] = [
            InUseRecordSummary(recordNumber: 16, isBaseRecord: true, baseRecordNumber: nil),
        ]
        let split = MFTConsistency.splitLeakedExtensions(
            records,
            leakedExtensions: [18],
            basesConfirmedFree: [99]
        )
        XCTAssertEqual(split.baseFreeExtensions, [],
                       "a leaked extension absent from `records` can't be proven reclaimable")
        XCTAssertEqual(split.baseUnresolvedExtensions, [18],
                       "an extension whose base recnum is unknown defaults to deferred")
    }

    /// Mixed: two leaked extensions, one base confirmed free and one not —
    /// each routes to exactly one side of the split.
    func testSplitLeakedExtensionsMixed() {
        let records: [InUseRecordSummary] = [
            // extension 18 → base 99 (will be confirmed free → reclaimable)
            InUseRecordSummary(recordNumber: 18, isBaseRecord: false, baseRecordNumber: 99),
            // extension 19 → base 88 (NOT confirmed free → deferred)
            InUseRecordSummary(recordNumber: 19, isBaseRecord: false, baseRecordNumber: 88),
        ]
        let split = MFTConsistency.splitLeakedExtensions(
            records,
            leakedExtensions: [18, 19],
            basesConfirmedFree: [99]
        )
        XCTAssertEqual(split.baseFreeExtensions, [18],
                       "only the extension whose base (99) was confirmed free is reclaimable")
        XCTAssertEqual(split.baseUnresolvedExtensions, [19],
                       "the extension whose base (88) was not confirmed free is deferred")
    }
}
