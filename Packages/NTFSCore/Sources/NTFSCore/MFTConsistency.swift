import Foundation

// Pure, disk-I/O-free classification of an MFT sweep's IN_USE records into
// base records, orphaned base records, and extension records (legitimate vs.
// leaked). This is the shared brain behind `ntfsctl verify` and `ntfsctl
// reclaim-orphans` so the two commands agree exactly on what counts as an
// orphan — and, critically, on what must NEVER be freed.
//
// WHY this exists (the bug it fixes):
//   Since v0.5 Fix B Steps 3/4 the driver migrates an overflowing
//   $INDEX_ALLOCATION (0xA0) or unnamed $DATA (0x80) attribute out of a base
//   MFT record into a fresh *extension* record (one with a non-zero
//   baseFileReference). An extension record is legitimately IN_USE but is
//   reachable ONLY through its base record's baseFileReference — it never has
//   its own $I30 directory entry. The old orphan walk (inUse \ reachable)
//   therefore flagged every extension record as an "orphan", and
//   reclaim-orphans would have FREED it — which detaches the migrated
//   $DATA/$INDEX_ALLOCATION from a live file and corrupts the base. So the
//   sweep must distinguish base records (which CAN be orphaned and reclaimed)
//   from extension records (which must be classified by whether their base is
//   in use, and never reclaimed).

/// A lightweight, value-type summary of one IN_USE MFT record, carrying only
/// what the classifier needs. Decoupled from `MFTRecord` so unit tests can
/// construct these directly without a backing disk image (the on-disk record
/// builder only produces base records — see `MFTRecordBuilder` — so real
/// extension records can't be synthesized in a pure unit test).
public struct InUseRecordSummary: Sendable, Equatable {
    /// This record's own MFT record number.
    public let recordNumber: UInt64
    /// True iff `baseFileReference == 0` (a base record). False ⇒ extension.
    public let isBaseRecord: Bool
    /// `nil` for a base record; for an extension, the record number of the base
    /// it belongs to (the low 48 bits of its packed `baseFileReference`).
    public let baseRecordNumber: UInt64?

    public init(recordNumber: UInt64, isBaseRecord: Bool, baseRecordNumber: UInt64?) {
        self.recordNumber = recordNumber
        self.isBaseRecord = isBaseRecord
        self.baseRecordNumber = baseRecordNumber
    }
}

/// The result of classifying an MFT sweep. The four sets partition the IN_USE
/// user records (recnum >= 16) by role and health.
public struct MFTClassification: Sendable, Equatable {
    /// All IN_USE base records (recnum >= 16). A base record holds (or once
    /// held) a file's resident metadata and is reachable via a $I30 entry.
    public var baseRecords: Set<UInt64>
    /// IN_USE base records NOT reachable from root's $I30 tree — true orphans.
    /// These are the only records `reclaim-orphans` may free.
    public var orphanBaseRecords: Set<UInt64>
    /// Extension records whose base record IS an IN_USE base — legitimately in
    /// use (their migrated $DATA / $INDEX_ALLOCATION belongs to that live base
    /// file). Reachable only via baseFileReference, never via $I30, so they are
    /// EXPECTED to be absent from the reachable set. NEVER an orphan; NEVER
    /// freeable — freeing one corrupts the base file.
    public var legitimateExtensions: Set<UInt64>
    /// Extension records whose claimed base record is NOT an IN_USE base — a
    /// genuine defect (a leaked extension whose owner is gone). Surfaced as a
    /// distinct error class; recommend `chkdsk /f`. Still NEVER auto-freed in
    /// v0.5 (freeing requires also fixing up the base / $ATTRIBUTE_LIST).
    public var leakedExtensions: Set<UInt64>

    public init(
        baseRecords: Set<UInt64> = [],
        orphanBaseRecords: Set<UInt64> = [],
        legitimateExtensions: Set<UInt64> = [],
        leakedExtensions: Set<UInt64> = []
    ) {
        self.baseRecords = baseRecords
        self.orphanBaseRecords = orphanBaseRecords
        self.legitimateExtensions = legitimateExtensions
        self.leakedExtensions = leakedExtensions
    }
}

/// `classifyInUseRecords`'s `leakedExtensions` set conflates two very different
/// situations, because the classifier is pure and builds `baseRecords` only
/// from the IN_USE records the sweep SUCCESSFULLY PARSED. A leaked extension is
/// therefore "extension whose base recnum isn't in the parsed-in-use set" —
/// which means the base is EITHER genuinely FREE (dead extension, reclaimable)
/// OR IN_USE-but-unparseable (a LIVE file whose extension must NOT be freed).
/// This split lets the caller separate the two by AUTHORITATIVELY reading each
/// extension's base record off disk and reporting which bases it confirmed free.
public struct LeakedExtensionSplit: Sendable, Equatable {
    /// Leaked extension whose base record was read and confirmed IN_USE=0 — the
    /// base is genuinely gone, so the extension is dead and reclaimable (free
    /// its clusters + slot).
    public var baseFreeExtensions: Set<UInt64>
    /// Leaked extension whose base could NOT be confirmed free (base IN_USE,
    /// unparseable, or unresolvable) — could be a live file; NEVER auto-freed,
    /// defer to `chkdsk /f`.
    public var baseUnresolvedExtensions: Set<UInt64>

    public init(
        baseFreeExtensions: Set<UInt64> = [],
        baseUnresolvedExtensions: Set<UInt64> = []
    ) {
        self.baseFreeExtensions = baseFreeExtensions
        self.baseUnresolvedExtensions = baseUnresolvedExtensions
    }
}

public enum MFTConsistency {
    /// Low 48 bits of a packed MFT reference hold the record number; the high
    /// 16 bits hold the sequence number. `baseFileReference` is packed the same
    /// way (see `MFTRecord` on-disk layout, offset 32).
    public static let recordNumberMask: UInt64 = 0x0000_FFFF_FFFF_FFFF

    /// Extract the base record number from a packed `baseFileReference`. The
    /// sequence number (high 16 bits) is intentionally discarded — the sweep
    /// matches extensions to bases by record number.
    public static func baseRecordNumber(fromBaseFileReference ref: UInt64) -> UInt64 {
        ref & recordNumberMask
    }

    /// Classify a set of IN_USE user records against the set of record numbers
    /// reachable from root's $I30 tree.
    ///
    /// - `baseRecords`: every summary with `isBaseRecord == true`.
    /// - `orphanBaseRecords`: base records whose recnum is NOT in `reachable`.
    /// - `legitimateExtensions`: extension records whose `baseRecordNumber` is
    ///   itself an IN_USE base — legitimately in use (owned by a live file),
    ///   so NOT an orphan even though it is unreachable via $I30.
    /// - `leakedExtensions`: extension records whose `baseRecordNumber` is NOT
    ///   an IN_USE base — a real defect (dangling extension).
    ///
    /// Reachability is irrelevant for extensions: extensions are NEVER reached
    /// through $I30, so we classify them solely by whether their base is in use.
    public static func classifyInUseRecords(
        _ records: [InUseRecordSummary],
        reachable: Set<UInt64>
    ) -> MFTClassification {
        let baseRecords = Set(records.filter { $0.isBaseRecord }.map { $0.recordNumber })

        var orphanBaseRecords: Set<UInt64> = []
        var legitimateExtensions: Set<UInt64> = []
        var leakedExtensions: Set<UInt64> = []

        for record in records {
            if record.isBaseRecord {
                // A base record is an orphan iff it isn't reachable from root.
                if !reachable.contains(record.recordNumber) {
                    orphanBaseRecords.insert(record.recordNumber)
                }
            } else {
                // Extension: legitimate iff its base is an IN_USE base record.
                // Otherwise its owner is gone — a leaked extension (real defect).
                let base = record.baseRecordNumber ?? Self.recordNumberMask
                if baseRecords.contains(base) {
                    legitimateExtensions.insert(record.recordNumber)
                } else {
                    leakedExtensions.insert(record.recordNumber)
                }
            }
        }

        return MFTClassification(
            baseRecords: baseRecords,
            orphanBaseRecords: orphanBaseRecords,
            legitimateExtensions: legitimateExtensions,
            leakedExtensions: leakedExtensions
        )
    }

    /// Split `classification.leakedExtensions` by the AUTHORITATIVE state of
    /// each extension's base record. The caller must have read every distinct
    /// base record off disk and passed in `basesConfirmedFree` — the set of base
    /// recnums it found IN_USE=0. A leaked extension is reclaimable iff its base
    /// recnum is in `basesConfirmedFree`; everything else is deferred.
    ///
    /// - `records`: the same summaries passed to `classifyInUseRecords`; supplies
    ///   each extension's `baseRecordNumber`.
    /// - `leakedExtensions`: the leaked set to split.
    /// - `basesConfirmedFree`: base recnums the caller AUTHORITATIVELY read and
    ///   found IN_USE=0.
    ///
    /// Default-deny: a leaked extension whose base is not in `basesConfirmedFree`
    /// — including one whose base recnum can't be found in `records` at all —
    /// goes to `baseUnresolvedExtensions`. Only a base PROVABLY free yields a
    /// reclaimable extension.
    public static func splitLeakedExtensions(
        _ records: [InUseRecordSummary],
        leakedExtensions: Set<UInt64>,
        basesConfirmedFree: Set<UInt64>
    ) -> LeakedExtensionSplit {
        var baseByRecnum: [UInt64: UInt64] = [:]
        for record in records where !record.isBaseRecord {
            if let base = record.baseRecordNumber {
                baseByRecnum[record.recordNumber] = base
            }
        }

        var split = LeakedExtensionSplit()
        for recnum in leakedExtensions {
            if let base = baseByRecnum[recnum], basesConfirmedFree.contains(base) {
                split.baseFreeExtensions.insert(recnum)
            } else {
                split.baseUnresolvedExtensions.insert(recnum)
            }
        }
        return split
    }
}
