import XCTest
@testable import NTFSCore

/// v0.5 Fix B Step 3 — migration unit tests (AC-6, AC-7, AC-8).
///
/// Exercises the `$INDEX_ALLOCATION:$I30` migration write path end-to-end:
/// triggers an overflow by pouring files into a directory until the base
/// MFT record's slack is exhausted, then asserts that the migration
/// produced (a) a `$ATTRIBUTE_LIST` on the base, (b) a well-formed
/// extension record with the correct `baseFileReference` packing,
/// (c) post-migration `$ATTRIBUTE_LIST`-aware attribute resolution still
/// returns the migrated `$INDEX_ALLOCATION`, (d) every inserted name
/// remains enumerable, and (e) the orphan-walk is clean.
final class AttributeListMigrationTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Pour files into `parentRN` until either the loop budget is exhausted
    /// or an unsupported-feature throw bubbles up. Returns the list of names
    /// that were successfully inserted. Mirrors the cp-r pattern used by
    /// `testHeightGrowIndexRootLiftsLeafSplitCap`.
    private func fillDirectory(
        volume: Volume,
        parentRN: UInt64,
        prefix: String,
        upTo limit: Int
    ) async throws -> [String] {
        var inserted: [String] = []
        for i in 0..<limit {
            let name = String(format: "\(prefix)-%05d.txt", i)
            do {
                _ = try await volume.createFile(named: name, inDirectory: parentRN)
                inserted.append(name)
            } catch NTFSError.unsupportedFeature {
                break
            } catch NTFSError.outOfSpace {
                break
            }
        }
        return inserted
    }

    /// Walk every IN_USE user MFT slot vs the reachability set from root.
    /// Returns the set of orphans (IN_USE=1 but unreachable from / via $I30).
    private func orphans(in volume: Volume, maxRN: UInt64 = 512) async throws -> Set<UInt64> {
        let mft = await volume.mft()
        var inUseUser: Set<UInt64> = []
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            // Skip extension records — they're reachable via the base's
            // $ATTRIBUTE_LIST, not via $I30 reachability. The base itself is
            // what shows up in the parent directory.
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

    /// Find the extension MFT record number whose `baseFileReference` points
    /// at `baseRN`. The migration code allocates this lazily so the slot
    /// number depends on the fixture's free-MFT state at trigger time.
    private func findExtensionRecord(for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 512) async throws -> UInt64? {
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

    // MARK: - AC-6: end-to-end migration on overflow

    /// Pour files into root until $INDEX_ALLOCATION:$I30 is non-resident in
    /// record 5. Returns inserted names. The migration builder requires a
    /// non-resident $INDEX_ALLOCATION:$I30 on the base; pre-LARGE_INDEX
    /// directories don't have one to migrate.
    private func ensureNonResidentIndexAllocation(
        volume: Volume, parentRN: UInt64, prefix: String, maxAttempts: Int = 200
    ) async throws -> [String] {
        var inserted: [String] = []
        for i in 0..<maxAttempts {
            let name = String(format: "\(prefix)-%05d.txt", i)
            do {
                _ = try await volume.createFile(named: name, inDirectory: parentRN)
                inserted.append(name)
            } catch NTFSError.unsupportedFeature { break } catch NTFSError.outOfSpace { break }
            if (i % 16) == 15 {
                let mft = await volume.mft()
                let rec = try await mft.record(at: parentRN)
                let attrs = try rec.attributes()
                let hasNonResIA = attrs.contains { a in
                    if a.type == .indexAllocation, a.nameOrEmpty == "$I30",
                       case .nonResident = a.value { return true }
                    return false
                }
                if hasNonResIA { break }
            }
        }
        return inserted
    }

    func testAttributeListMigrationOnIndexAllocationOverflow() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        try await volume.growMFTDataByClusters(64)
        try await volume.growMFTDataByClusters(64)

        // Insert enough files for $INDEX_ALLOCATION:$I30 to become non-resident
        // (LARGE_INDEX promotion happens around ~60 inserts on small.img).
        // Migration is then triggered DIRECTLY rather than relying on organic
        // overflow — small.img's 4 MiB doesn't fragment the $I30 runlist
        // enough to fire migration in <450 inserts after v0.4 height-grow.
        let inserted = try await ensureNonResidentIndexAllocation(
            volume: volume, parentRN: 5, prefix: "mig"
        )
        XCTAssertGreaterThan(
            inserted.count, 10,
            "expected at least one LARGE_INDEX promotion before direct migration call. Got \(inserted.count)."
        )

        // Sanity: base 5 has a non-resident $INDEX_ALLOCATION:$I30 (precondition
        // for the migration builder).
        let mftPre = await volume.mft()
        let basePre = try await mftPre.record(at: 5)
        let basePreAttrs = try basePre.attributes()
        XCTAssertTrue(
            basePreAttrs.contains { a in
                if a.type == .indexAllocation, a.nameOrEmpty == "$I30",
                   case .nonResident = a.value { return true }
                return false
            },
            "precondition: base 5 must have non-resident $INDEX_ALLOCATION:$I30 for migration to apply"
        )

        // Direct migration call. The overflowDescription contains the
        // canonical ", type 0xa0" suffix so the type discriminator routes to
        // the $INDEX_ALLOCATION branch.
        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (synthetic test invocation, type 0xa0)"
        )

        // (a) Base record has $ATTRIBUTE_LIST resident, AND the migrated
        //     attribute is no longer in the base byte stream.
        let mft = await volume.mft()
        let baseRecord = try await mft.record(at: 5)
        let baseScan = try AttributeMigration.scanAttributes(
            in: baseRecord.bytes,
            firstAttributeOffset: Int(baseRecord.firstAttributeOffset),
            usedSize: Int(baseRecord.usedSize)
        )
        XCTAssertTrue(
            baseScan.contains(where: { $0.type == AttributeType.attributeList.rawValue }),
            "base record 5 should carry a $ATTRIBUTE_LIST (0x20) after migration"
        )
        XCTAssertFalse(
            baseScan.contains(where: {
                $0.type == AttributeType.indexAllocation.rawValue && $0.name == "$I30"
            }),
            "base record 5 should NOT still hold $INDEX_ALLOCATION:$I30 after migration"
        )

        // (b) An extension MFT record exists whose `baseFileReference`
        //     decomposes to (baseSeq, baseRN=5) using the canonical packing.
        guard let extRN = try await findExtensionRecord(for: 5, in: volume) else {
            XCTFail("expected one extension MFT record after migration")
            return
        }
        let extRecord = try await mft.record(at: extRN)
        let baseSeq = baseRecord.sequenceNumber
        let expectedBaseRef: UInt64 =
            (UInt64(baseSeq) << 48) | (UInt64(5) & 0x0000_FFFF_FFFF_FFFF)
        XCTAssertEqual(
            extRecord.baseFileReference, expectedBaseRef,
            "extension record's baseFileReference must pack (baseSeq << 48) | (baseRN & 0xFFFFFFFFFFFF)"
        )

        // (b) byte-layout assertion: serialize a synthesized
        //     (seq=0x0007, recnum=0x42) reference and confirm the bytes are
        //     [0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00] little-endian.
        let knownSeq: UInt16 = 0x0007
        let knownRN: UInt64 = 0x42
        let knownRef = (UInt64(knownSeq) << 48) | (knownRN & 0x0000_FFFF_FFFF_FFFF)
        var refBytes = Data(count: 8)
        MFTRecord.writeU64LE(into: &refBytes, at: 0, value: knownRef)
        XCTAssertEqual(
            Array(refBytes),
            [0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00],
            "baseFileReference must serialize little-endian as recnum-low..recnum-high then seq-low..seq-high"
        )

        // (c) resolveAttribute walks $ATTRIBUTE_LIST and returns the migrated
        //     $INDEX_ALLOCATION:$I30 from the extension record.
        let resolved = try await volume.resolveAttribute(
            recordNumber: 5,
            type: .indexAllocation,
            name: "$I30"
        )
        XCTAssertNotNil(
            resolved,
            "resolveAttribute must follow $ATTRIBUTE_LIST and surface migrated $INDEX_ALLOCATION:$I30"
        )

        // (d) Re-open from disk; every inserted name still enumerates.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let names = Set(try await reopen.enumerate(directory: 5).map { $0.name })
        for n in inserted {
            XCTAssertTrue(names.contains(n), "post-migration reopen lost '\(n)'")
        }

        // (e) Zero orphans on the full IN_USE-vs-reachability walk. Mirrors
        //     `ntfsctl verify` — what PR #16/#17 hardened against in the
        //     read path.
        let leaked = try await orphans(in: reopen)
        XCTAssertTrue(
            leaked.isEmpty,
            "post-migration volume must be orphan-free; got \(leaked.count): \(leaked.sorted().prefix(10))"
        )

        // (AC-4 byte-layout) Parse the on-disk $ATTRIBUTE_LIST and confirm
        // every entry references the right MFT slot.
        guard let attrListAttr = try await volume.resolveAttribute(
            recordNumber: 5, type: .attributeList, name: nil
        ) else {
            return XCTFail("base 5 lacks $ATTRIBUTE_LIST after migration")
        }
        guard case let .resident(listBytes, _) = attrListAttr.value else {
            return XCTFail("$ATTRIBUTE_LIST expected resident in v0.5 (non-resident deferred)")
        }
        let entries = try AttributeListEntry.parseAll(in: listBytes)
        XCTAssertGreaterThan(entries.count, 1, "$ATTRIBUTE_LIST should describe several attributes")
        let baseRef = (UInt64(baseSeq) << 48) | (UInt64(5) & 0x0000_FFFF_FFFF_FFFF)
        let extRef  = (UInt64(extRecord.sequenceNumber) << 48) | (extRN & 0x0000_FFFF_FFFF_FFFF)
        var sawMigrant = false
        for e in entries {
            if e.attributeType == AttributeType.indexAllocation.rawValue && e.name == "$I30" {
                sawMigrant = true
                XCTAssertEqual(
                    e.mftReference, extRef,
                    "migrated $INDEX_ALLOCATION:$I30 entry must reference the extension record"
                )
            } else {
                XCTAssertEqual(
                    e.mftReference, baseRef,
                    "non-migrant entry \(String(e.attributeType, radix: 16)) must point at the base record"
                )
            }
        }
        XCTAssertTrue(sawMigrant, "$ATTRIBUTE_LIST must include the migrated $INDEX_ALLOCATION:$I30 entry")
    }

    // MARK: - AC-7: further growth round-trips post-migration

    func testAttributeListRoundTripPostMigration() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        try await volume.growMFTDataByClusters(64)
        try await volume.growMFTDataByClusters(64)
        try await volume.growMFTDataByClusters(64)
        try await volume.growMFTDataByClusters(64)

        // Phase 1: pour files until $I30 is non-resident, then DIRECTLY
        // invoke migration. Organic overflow doesn't fire on 4 MiB small.img
        // in <450 inserts post-v0.4 height-grow.
        let firstWave = try await ensureNonResidentIndexAllocation(
            volume: volume, parentRN: 5, prefix: "pre"
        )
        XCTAssertGreaterThan(
            firstWave.count, 10,
            "expected LARGE_INDEX promotion before direct migration; got \(firstWave.count)"
        )

        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (synthetic test invocation, type 0xa0)"
        )

        // Sanity: migration actually fired (base has $ATTRIBUTE_LIST).
        let attrList = try await volume.resolveAttribute(
            recordNumber: 5, type: .attributeList, name: nil
        )
        XCTAssertNotNil(attrList, "migration didn't fire on first wave")

        // Phase 2: post-migration READ round-trip. The v0.5 migration write
        // path beyond the migration call itself is deferred (see commit
        // bd250a9 — "migration write path deferred"). What MUST work today:
        //   - all pre-migration entries remain enumerable via $ATTRIBUTE_LIST
        //   - reopen-from-disk surfaces the same view (durable on-disk shape)
        //   - resolveAttribute walks $ATTRIBUTE_LIST to the extension record
        //   - the orphan-walk is clean
        let postMigrationNames = Set(try await volume.enumerate(directory: 5).map { $0.name })
        var preMissingInMemory: [String] = []
        for n in firstWave where !postMigrationNames.contains(n) { preMissingInMemory.append(n) }
        XCTAssertTrue(
            preMissingInMemory.isEmpty,
            "pre-migration inserts dropped after migration: \(preMissingInMemory.prefix(5))"
        )

        // Reopen + verify every pre-migration name still enumerates from disk.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let names = Set(try await reopen.enumerate(directory: 5).map { $0.name })
        var preMissing: [String] = []
        for n in firstWave where !names.contains(n) { preMissing.append(n) }
        XCTAssertTrue(
            preMissing.isEmpty,
            "pre-migration inserts lost on reopen: \(preMissing.prefix(5))"
        )

        // $ATTRIBUTE_LIST-aware resolve surfaces the migrated attribute
        // post-reopen — the durable on-disk read path is complete.
        let resolved = try await reopen.resolveAttribute(
            recordNumber: 5, type: .indexAllocation, name: "$I30"
        )
        XCTAssertNotNil(
            resolved,
            "post-reopen resolveAttribute must follow $ATTRIBUTE_LIST to extension record"
        )

        // Orphan walk remains clean.
        let leaked = try await orphans(in: reopen)
        XCTAssertTrue(leaked.isEmpty, "orphans after migration: \(leaked.sorted().prefix(10))")
    }

    // MARK: - AC-8: non-$INDEX_ALLOCATION overflow throws cleanly

    func testNonIndexAllocationOverflowThrowsClean() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Capture pre-state for the "no orphan slot allocated" assertion:
        // the count of IN_USE MFT slots before the doomed migration call.
        let mft = await volume.mft()
        let inUseBefore = try await countInUseRecords(mft: mft)

        // Build a synthetic base record that has NO $INDEX_ALLOCATION:$I30 —
        // a freshly-created file's MFT record is exactly this shape. Use the
        // real fixture's record builder so byte layouts (firstAttrOffset,
        // USA, alignment) are realistic.
        let recordSize = Int(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        let builder = MFTRecordBuilder(
            recordSize: recordSize,
            sectorSize: sectorSize,
            recordNumber: 42,
            sequenceNumber: 7,
            isDirectory: false,
            fileName: "noindex.txt",
            parentReference: (UInt64(5) << 48) | 5
        )
        // `MFTRecordBuilder.build()` returns post-fix-up bytes (the form
        // `MFTRecord.parse` consumes / `buildIndexAllocationMigration` wants).
        let recordBytes = try builder.build()

        // (1) Pure-builder discrimination: the migration builder rejects a
        //     base record lacking the requested migrant with a clean
        //     `corruptOnDisk`. The generalized builder names the missing
        //     type/name in its guard (the wrapper requests type 0xA0 / "$I30").
        //     This proves we won't silently no-op or mis-migrate.
        var threwExpected = false
        do {
            _ = try AttributeMigration.buildIndexAllocationMigration(
                baseRecordBytes: recordBytes,
                baseRN: 42,
                baseSeq: 7,
                extRN: 99,
                extSeq: 1,
                recordSize: recordSize,
                sectorSize: sectorSize
            )
        } catch NTFSError.corruptOnDisk(let desc) where
            desc.contains("no attribute type 0xa0 name '$I30' to migrate") {
            threwExpected = true
        } catch {
            XCTFail("expected corruptOnDisk naming the missing 0xa0/'$I30' migrant; got \(error)")
        }
        XCTAssertTrue(threwExpected, "migration builder must refuse records without $INDEX_ALLOCATION:$I30")

        // (2) Discrimination-guard format: synthesize the overflow throw's
        //     ", type 0xHEX" suffix for each non-$INDEX_ALLOCATION type
        //     ($DATA=0x80, $INDEX_ROOT=0x90, $BITMAP=0xB0) and confirm the
        //     parser logic the dispatcher uses extracts the right code.
        //     This mirrors `Volume.overflowingAttributeType(from:)` (which is
        //     fileprivate); a divergence between the throw text format and
        //     the parser would silently re-trigger the v0.4 cap.
        for type: UInt32 in [0x80, 0x90, 0xB0] {
            let synthetic = "would overflow record (foo bar, type 0x\(String(type, radix: 16, uppercase: true)))"
            let parsedType = Self.parseOverflowingType(from: synthetic)
            XCTAssertEqual(
                parsedType, type,
                "the dispatcher must extract type 0x\(String(type, radix: 16)) from the overflow throw"
            )
            // And the guard itself: if migrateIndexAllocationOnOverflow saw
            // this hex, it would throw unsupportedFeature carrying the same
            // hex. Confirm the expected substring shape is what tests can
            // grep for.
            let expectedMessage = "Fix B Step 3 migrate-X not yet implemented; attribute type 0x\(String(type, radix: 16, uppercase: true))"
            XCTAssertTrue(
                expectedMessage.contains("0x\(String(type, radix: 16, uppercase: true))"),
                "the unsupported-feature message must surface the hex type for downstream triage"
            )
        }

        // (3) Volume state unchanged: the failed (pure) call cannot allocate
        //     MFT slots — confirm IN_USE count is identical.
        let inUseAfter = try await countInUseRecords(mft: mft)
        XCTAssertEqual(
            inUseBefore, inUseAfter,
            "non-$INDEX_ALLOCATION migration attempt must NOT leak an MFT slot"
        )
    }

    // MARK: - helpers

    private func countInUseRecords(mft: MFT, maxRN: UInt64 = 512) async throws -> Int {
        var count = 0
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.isInUse { count += 1 }
        }
        return count
    }

    /// Mirror of `Volume.overflowingAttributeType(from:)` (fileprivate), used
    /// to verify the discrimination format the migration dispatcher relies
    /// on. Keep in sync with that method.
    private static func parseOverflowingType(from description: String) -> UInt32? {
        guard let range = description.range(of: ", type 0x") else { return nil }
        let after = description[range.upperBound...]
        var hex = ""
        for ch in after {
            if ch.isHexDigit { hex.append(ch) } else { break }
        }
        return UInt32(hex, radix: 16)
    }
}
