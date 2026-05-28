import XCTest
@testable import NTFSCore

/// v0.7 — multi-extension `$INDEX_ALLOCATION` reproduction + AC-5/6 stubs.
///
/// This file's reproduction test (`testReproducesV06SecondMigrationCeiling`)
/// asserts the *current* (post-PR-#34, pre-v0.7-fix) behavior: pouring enough
/// entries into a single directory drives its `$INDEX_ALLOCATION:$I30` runlist
/// past the point that one extension MFT record can hold, and the leaf-split
/// catch path responds by throwing a clean, user-actionable
/// `NTFSError.unsupportedFeature(...)` mentioning multi-extension `$ATTRIBUTE_LIST`.
///
/// The bug being tracked: "the system throws this v0.7 error at all" — i.e.
/// the ceiling exists. So this test PASSES when the ceiling fires (the bug
/// is reproduced) and SHOULD FAIL once Subtasks #2/#3 land (the migration
/// succeeds and no `unsupportedFeature` is thrown). At that point this
/// reproduction becomes obsolete and `testMultiExtensionIAReadbackRoundTrip`
/// takes over as the positive assertion.
///
/// The other four tests (`testMergeMultiExtensionAttribute_unitContract`,
/// `testMultiExtensionIAReadbackRoundTrip`, `testMultiExtensionIATransactionalFailure`,
/// `testMultiExtensionIASpecConformantBytes`) are AC-5/6 stubs — XCTSkip'd
/// pre-fix and enabled in subsequent subtasks.
final class MultiExtensionIndexAllocationTests: XCTestCase {

    // MARK: - fixture helper (mirrors AttributeListMigrationTests)

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Find an extension MFT record whose `baseFileReference` points at
    /// `baseRN`. Copied verbatim from AttributeListMigrationTests (those
    /// helpers are `private` to that file).
    private func findExtensionRecord(
        for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 1024
    ) async throws -> UInt64? {
        let mft = await volume.mft()
        let want = (UInt64(0) << 48) | (baseRN & 0x0000_FFFF_FFFF_FFFF)
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.baseFileReference != 0 && (rec.baseFileReference & mask) == (want & mask) {
                return rn
            }
        }
        return nil
    }

    /// Orphan walk (IN_USE base-records vs $I30-reachability from root).
    /// Copied verbatim from AttributeListMigrationTests.
    private func orphans(in volume: Volume, maxRN: UInt64 = 1024) async throws -> Set<UInt64> {
        let mft = await volume.mft()
        var inUseUser: Set<UInt64> = []
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.baseFileReference != 0 { continue }
            if rec.isInUse, rn >= 16 { inUseUser.insert(rn) }
        }
        var reachable: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dir = queue.popLast() {
            guard let entries = try? await volume.enumerate(directory: dir) else { continue }
            for e in entries where e.fileName.namespace != .dos {
                if !reachable.contains(e.recordNumber) {
                    reachable.insert(e.recordNumber)
                    if e.isDirectory { queue.append(e.recordNumber) }
                }
            }
        }
        return inUseUser.subtracting(reachable.filter { $0 >= 16 })
    }

    // MARK: - AC-1: reproduce v0.6 second-migration ceiling (MUST PASS pre-fix)

    /// AC-1 reproduction. Drives a single directory past the point where
    /// its already-migrated `$INDEX_ALLOCATION:$I30` extension record's own
    /// runlist outgrows ONE extension's MFT record. Pre-fix (HEAD on
    /// `feature/v07-multi-extension-index-allocation` at `main`@`ccc735d`
    /// + PR #34 merge): the leaf-split catch path invokes
    /// `migrateIndexAllocationOnOverflow` → `buildAttributeMigration` →
    /// the "already migrated" branch at AttributeMigration.swift:133
    /// throws `unsupportedFeature(...)` with the
    /// "multi-extension $ATTRIBUTE_LIST required" message.
    ///
    /// After Subtasks #2/#3 land, this test SHOULD FAIL — i.e. no
    /// `unsupportedFeature` is thrown because the second extension is
    /// allocated transparently and the loop runs to completion. That's
    /// the post-fix expected outcome; at that point this test becomes
    /// obsolete and the AC-6 round-trip test takes over.
    func testReproducesV06SecondMigrationCeiling() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Pre-grow MFT modestly so the early inserts aren't bounded by
        // the v0.2 "MFT auto-grow disabled" error.
        try await volume.growMFTDataByClusters(64)
        try await volume.growMFTDataByClusters(64)

        // STAGE 1: drive enough inserts that `$INDEX_ALLOCATION:$I30`
        // becomes non-resident on root (record 5). This is the precondition
        // for migration. Mirrors the `ensureNonResidentIndexAllocation`
        // helper in AttributeListMigrationTests.
        let mftA = await volume.mft()
        var insertedStage1 = 0
        for i in 0..<400 {
            let name = String(format: "stage1-%05d.txt", i)
            do {
                _ = try await volume.createFile(named: name, inDirectory: 5)
                insertedStage1 += 1
            } catch NTFSError.outOfSpace { break }
              catch NTFSError.unsupportedFeature { break }
            if (i % 16) == 15 {
                let rec = try await mftA.record(at: 5)
                let attrs = try rec.attributes()
                let hasNonResIA = attrs.contains { a in
                    if a.type == .indexAllocation, a.nameOrEmpty == "$I30",
                       case .nonResident = a.value { return true }
                    return false
                }
                if hasNonResIA { break }
            }
        }
        // Precondition: base 5 now has non-resident $INDEX_ALLOCATION:$I30.
        let basePreMig = try await mftA.record(at: 5)
        let basePreAttrs = try basePreMig.attributes()
        XCTAssertTrue(
            basePreAttrs.contains { a in
                if a.type == .indexAllocation, a.nameOrEmpty == "$I30",
                   case .nonResident = a.value { return true }
                return false
            },
            "precondition for AC-1 reproduction: base 5 must have non-resident $INDEX_ALLOCATION:$I30 after \(insertedStage1) inserts"
        )

        // STAGE 2: drive the FIRST migration ($INDEX_ALLOCATION:$I30 → an
        // extension record, $ATTRIBUTE_LIST appears on the base). The
        // existing migration unit test invokes this synthetically; we do
        // the same since 4 MiB small.img doesn't fragment enough to fire
        // it organically in <450 inserts.
        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (AC-1 reproduction stage 2, type 0xa0)"
        )

        // Sanity: post-stage-2, base 5 carries $ATTRIBUTE_LIST and NO
        // $INDEX_ALLOCATION:$I30 itself — exactly the "already migrated"
        // shape the second migration call must encounter.
        let baseMid = try await mftA.record(at: 5)
        let midAttrs = try baseMid.attributes()
        XCTAssertTrue(
            midAttrs.contains { $0.rawType == AttributeType.attributeList.rawValue },
            "post-stage-2: base 5 must carry $ATTRIBUTE_LIST"
        )
        XCTAssertFalse(
            midAttrs.contains { $0.type == .indexAllocation && $0.nameOrEmpty == "$I30" },
            "post-stage-2: base 5 must NOT still hold $INDEX_ALLOCATION:$I30 in its own attribute stream"
        )

        // STAGE 3: invoke migrateIndexAllocationOnOverflow on base 5 a
        // SECOND time. The leaf-split catch path will do this whenever the
        // (already-migrated) extension's runlist outgrows its container —
        // we're simulating that condition directly because small.img
        // (4 MiB) cannot grow a single directory's runlist beyond an
        // extension record's ~900-byte budget before running out of
        // clusters entirely (we measured: ~569 inserts max, far short
        // of the runlist mass needed). The PR #34 catch site at
        // AttributeMigration.swift:133 detects the "already migrated"
        // shape via the resident $ATTRIBUTE_LIST + absent migrant and
        // throws the user-actionable multi-extension message — exactly
        // the v0.6.x ceiling this v0.7 work is lifting.
        var caughtMessage: String? = nil
        var caughtOther: Error? = nil
        do {
            try await volume.migrateIndexAllocationOnOverflow(
                baseRecordNumber: 5,
                overflowDescription: "would overflow record (AC-1 reproduction stage 3, type 0xa0)"
            )
        } catch let NTFSError.unsupportedFeature(desc) {
            caughtMessage = desc
        } catch {
            caughtOther = error
        }

        let insertedCount = insertedStage1

        if let desc = caughtMessage {
            // The PR #34 message at AttributeMigration.swift:133. Match the
            // structural keywords ("multi-extension" + "$ATTRIBUTE_LIST"),
            // NOT the "v0.7" wording — that may evolve.
            XCTAssertTrue(
                desc.contains("multi-extension"),
                "expected multi-extension hint in unsupportedFeature message; got: \(desc)"
            )
            XCTAssertTrue(
                desc.contains("$ATTRIBUTE_LIST"),
                "expected $ATTRIBUTE_LIST mention in unsupportedFeature message; got: \(desc)"
            )
            // Sanity: make sure we're hitting the AttributeMigration.swift:133
            // throw site (post-first-migration ceiling), NOT the :204
            // "$ATTRIBUTE_LIST exceeds parent slack" throw (a DIFFERENT
            // ceiling — non-resident $ATTRIBUTE_LIST, not multi-extension).
            XCTAssertFalse(
                desc.contains("exceeds parent slack"),
                "wrong throw site: hit :204 (non-resident $ATTRIBUTE_LIST) not :133 (multi-extension). msg: \(desc)"
            )
            // For follow-up worker observability: dump the actual message
            // so test output records the exact reproduction text.
            print("AC-1 reproduction caught at inserted=\(insertedCount): \(desc)")
        } else if let err = caughtOther {
            XCTFail(
                """
                stage-3 migrateIndexAllocationOnOverflow expected to throw \
                unsupportedFeature("multi-extension required") on a base record that \
                already has $ATTRIBUTE_LIST. Instead got: \(err). \
                Stage-1 inserts: \(insertedCount).
                """
            )
        } else {
            XCTFail(
                """
                stage-3 migrateIndexAllocationOnOverflow returned cleanly with no throw \
                after \(insertedCount) stage-1 inserts. Either the v0.7 multi-extension fix \
                (Subtasks #2/#3) has landed — in which case this reproduction is obsolete \
                and should be removed in favour of testMultiExtensionIAReadbackRoundTrip — \
                or the builder no longer detects the 'already migrated' shape and is silently \
                doing the wrong thing.
                """
            )
        }
    }

    // MARK: - AC-5: mergeMultiExtensionAttribute unit contract (XCTSkip pre-fix)

    /// AC-5 unit test. The helper `Volume.mergeMultiExtensionAttribute(in:type:name:)`
    /// does not exist yet — it's introduced in Subtask #4. The test is
    /// skipped pre-fix so the harness records it as a TODO without breaking
    /// the build.
    ///
    /// Post-fix expected assertion (write this body once Subtask #4 lands):
    ///   - Synthesize two `Attribute` values via the parser (or a small
    ///     test helper) for `(rawType=0xA0, name="$I30")`:
    ///       attr1: startingVCN=0,  lastVCN=V1-1, extents=[E_a]
    ///       attr2: startingVCN=V1, lastVCN=V2,   extents=[E_b]
    ///   - Call `Volume.mergeMultiExtensionAttribute(in: [attr1, attr2], type: .indexAllocation, name: "$I30")`.
    ///   - Assert the returned `Attribute`:
    ///       * has `rawType == 0xA0` and `name == "$I30"`;
    ///       * `value` is `.nonResident(startingVCN: 0, lastVCN: V2, ..., extents: [E_a, E_b])`;
    ///       * extents are VCN-contiguous (no gap, no overlap);
    ///       * input order doesn't matter — passing `[attr2, attr1]` returns
    ///         an identical merged value.
    ///   - Also confirm `Volume.resolveAttribute` returns this merged view
    ///     (i.e. the change at Volume.swift:215-226 now routes through the
    ///     merge helper).
    func testMergeMultiExtensionAttribute_unitContract() throws {
        try XCTSkipIf(true, "AC-5 helper Volume.mergeMultiExtensionAttribute(...) not yet implemented (Subtask #4). See test doc-comment for the post-fix assertion body.")
    }

    // MARK: - AC-6.a: write past one extension, reopen, every name enumerates (XCTSkip pre-fix)

    /// AC-6.a round-trip. Post-fix body:
    ///   - Open small.img mutable, growMFTDataByClusters generously.
    ///   - Loop `createFile` over root for N names where N > the pre-fix cap
    ///     (i.e. comfortably past the file count at which testReproducesV06SecondMigrationCeiling
    ///     would have thrown). Track the inserted name set.
    ///   - Sanity-check the in-memory volume sees a multi-extension shape:
    ///     `findExtensionRecord(...)` must find >= 2 distinct extension
    ///     record numbers all pointing back at base 5; the base's
    ///     `$ATTRIBUTE_LIST` resident body parses into >= 2 entries with
    ///     `attributeType == 0xA0` and `name == "$I30"`.
    ///   - Close the volume, re-open RO from disk.
    ///   - Enumerate root and assert `Set(names)` equals the inserted set
    ///     exactly (no missing names, no extras). The "no missing" half is
    ///     what catches the silent half-read failure mode the AC-5 audit
    ///     guards against — if a consumer only sees the first extension's
    ///     runlist, the second extension's IA buckets and their entries
    ///     are invisible.
    ///   - `orphans(in: reopen)` is empty.
    func testMultiExtensionIAReadbackRoundTrip() throws {
        try XCTSkipIf(true, "Subtask #3 (Volume migration wiring) not yet implemented; round-trip cannot succeed until the second extension is allocated. See doc-comment for post-fix body.")
    }

    // MARK: - AC-6.b: transactional failure between extension-write and base-update (XCTSkip pre-fix)

    /// AC-6.b transactional-failure. Post-fix body:
    ///   - Open small.img mutable, growMFTDataByClusters generously.
    ///   - Drive the directory to the point JUST BEFORE the second
    ///     extension would be allocated (one insert before the ceiling
    ///     in the pre-fix world).
    ///   - Install a fault-injection seam on Volume — TODO(Subtask #3):
    ///     add an injectable closure to Volume that throws *after* the
    ///     new extension record's MFT slot is allocated + written but
    ///     *before* the base record's $ATTRIBUTE_LIST is updated to
    ///     reference it. The seam mirrors `_createFileFaultHook` (see
    ///     Volume.swift:62-90).
    ///   - Trigger one more `createFile`. Catch the injected error.
    ///   - Assert post-throw invariants:
    ///       * The newly-allocated extension MFT slot is `isInUse == 0`
    ///         (reclaimed on throw — mirrors `migrateAttributeOnOverflow`'s
    ///         existing reclaim-on-throw discipline).
    ///       * No extension record points at base 5 (or, more precisely:
    ///         the number of extensions referencing base 5 equals what it
    ///         was BEFORE the failing `createFile`).
    ///       * `orphans(in: reopen)` is empty after reopening the volume.
    ///       * A subsequent `createFile` (without the fault) succeeds,
    ///         allocating the same or a different extension slot — i.e.
    ///         the failed attempt left no poison.
    func testMultiExtensionIATransactionalFailure() throws {
        try XCTSkipIf(true, "Subtask #3 must add a fault-injection seam to Volume for the post-extension-write/pre-base-update window. See doc-comment for post-fix body.")
    }

    // MARK: - AC-6.c: $ATTRIBUTE_LIST bytes are spec-conformant (hand-decoded) (XCTSkip pre-fix)

    /// AC-6.c spec-conformance. PR #26 lesson: do NOT validate via our own
    /// decoder (round-tripping through `AttributeListEntry.parseAll` would
    /// mask bugs in our encoder if the bugs are symmetric). Instead,
    /// hand-decode the bytes per the spec.
    ///
    /// Post-fix body:
    ///   - Open small.img mutable, grow MFT, drive past the first
    ///     extension's capacity.
    ///   - `volume.resolveAttribute(recordNumber: 5, type: .attributeList, name: nil)`
    ///     and pattern-match `.resident(body, _)`.
    ///   - Walk `body` byte-by-byte (NOT via AttributeListEntry.parseAll):
    ///       * Read each 26-byte fixed entry header + variable-length
    ///         UTF-16 name.
    ///       * Collect every (attributeType, name, lowestVCN, mftReference)
    ///         tuple where `attributeType == 0xA0`.
    ///   - Assert:
    ///       * Exactly TWO 0xA0 entries are present (one per extension).
    ///       * Their UTF-16 names decode to "$I30" exactly (4 code units:
    ///         0x24 '$', 0x49 'I', 0x33 '3', 0x30 '0').
    ///       * Sorted by `lowestVCN`, the first entry's `lowestVCN == 0`
    ///         and the second's `lowestVCN == V1` (the documented split
    ///         point, > 0).
    ///       * The second entry's `mftReference & 0xFFFF_FFFF_FFFF` equals
    ///         the NEW extension's record number (not the first
    ///         extension's). Use `findExtensionRecord` then walk the MFT
    ///         to identify all extensions referencing base 5 and confirm
    ///         the second 0xA0 entry points at the second one (the
    ///         one with the lower-VCN-end != V1-1, or by ordering — pick
    ///         a robust criterion at fix time).
    ///       * The bit packing matches the canonical layout: `mft_reference`
    ///         is `(seq << 48) | (recnum & 0xFFFF_FFFF_FFFF)`. Verify by
    ///         re-reading the extension MFT record's sequence number and
    ///         comparing.
    func testMultiExtensionIASpecConformantBytes() throws {
        try XCTSkipIf(true, "Subtask #3 must produce the multi-extension on-disk shape first. See doc-comment for the hand-decoded spec-conformance assertion body.")
    }
}
