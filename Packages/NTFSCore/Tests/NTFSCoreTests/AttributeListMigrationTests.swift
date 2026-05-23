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

    // MARK: - delete-path migration helpers (mirror DataMigrationTests)

    /// Deterministic content generator so a multi-megabyte payload can be fed
    /// to `writeFile` without holding a separate reference copy.
    private static func contentByte(at i: UInt64) -> UInt8 {
        UInt8((i &* 31 &+ 7) & 0xFF)
    }

    /// Carve free space into a swiss-cheese bitmap (max contiguous run == 1
    /// cluster) so the subsequent `writeFile` is forced to allocate a long,
    /// highly-fragmented runlist. Returns free clusters remaining after carving.
    private func fragmentFreeSpace(_ volume: Volume) async throws -> UInt64 {
        var singles: [Extent] = []
        while let e = try? await volume.allocateClusters(1) {
            singles.append(e)
            if singles.count > 4096 { break }
        }
        for (i, e) in singles.enumerated() where i % 2 == 0 {
            try await volume.freeClusters(e)
        }
        return try await volume.allocationStats().freeClusters
    }

    /// Drive a fully-organic non-resident `$DATA` overflow on a fragmented
    /// volume — the cleanest *deletable* migrated object (root and migrated
    /// subdirs are not safely deletable). Mirrors `DataMigrationTests`'s helper.
    ///
    /// Returns the file's record number AND the free-cluster count measured
    /// *after* the swiss-cheese carve but *before* `writeFile` — i.e. the exact
    /// free count a subsequent `deleteFile(at: rn)` must restore (createFile's
    /// empty record costs no clusters; the carve's permanently-allocated holes
    /// are below this baseline and are NOT reclaimed by the delete). Returns
    /// `nil` if the fixture has too little free space to fragment for the
    /// requested overflow (caller XCTSkips).
    private func driveDataOverflow(
        volume: Volume,
        named name: String,
        inDirectory parentRN: UInt64 = 5,
        clusters: UInt64 = 260,
        fragment: Bool = true
    ) async throws -> (recordNumber: UInt64, freeBeforeWrite: UInt64)? {
        let rn = try await volume.createFile(named: name, inDirectory: parentRN)
        // `fragment: false` reuses the fragmentation an earlier file already
        // imposed on the volume — used by the two-file test, where a second
        // swiss-cheese carve would strand the remaining space and starve B.
        let freeBeforeWrite = fragment
            ? try await fragmentFreeSpace(volume)
            : try await volume.allocationStats().freeClusters
        guard freeBeforeWrite > clusters + 1 else { return nil }
        let total = Int(clusters * UInt64(volume.bytesPerCluster)) - 17
        var payload = Data(count: total)
        for i in 0..<total { payload[i] = Self.contentByte(at: UInt64(i)) }
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            let chunk = payload.subdata(in: cursor..<(cursor + take))
            cursor += take
            return chunk
        }
        return (rn, freeBeforeWrite)
    }

    /// True iff record `rn`'s base carries a `$ATTRIBUTE_LIST` (type 0x20) AND
    /// at least one extension record points back at it — i.e. migration fired.
    private func didMigrate(_ rn: UInt64, in volume: Volume) async throws -> Bool {
        let mft = await volume.mft()
        let attrs = try await mft.record(at: rn).attributes()
        let hasAttrList = attrs.contains { $0.rawType == AttributeType.attributeList.rawValue }
        let hasExt = try await findExtensionRecord(for: rn, in: volume) != nil
        return hasAttrList && hasExt
    }

    /// Collect every distinct extension record number belonging to base `rn`.
    private func extensionRecords(for rn: UInt64, in volume: Volume, maxRN: UInt64 = 512) async throws -> [UInt64] {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        var found: [UInt64] = []
        for ext: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: ext) else { continue }
            if rec.baseFileReference != 0, (rec.baseFileReference & mask) == (rn & mask) {
                found.append(ext)
            }
        }
        return found
    }

    /// Build `[InUseRecordSummary]` over the MFT and assert the pure classifier
    /// reports zero leaked extensions — a stronger orphan check than `orphans`.
    private func assertNoLeakedExtensions(in volume: Volume, file: StaticString = #filePath, line: UInt = #line) async throws {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        var summaries: [InUseRecordSummary] = []
        for rn: UInt64 in 16..<512 {
            guard let rec = try? await mft.record(at: rn), rec.isInUse else { continue }
            if rec.baseFileReference != 0 {
                summaries.append(InUseRecordSummary(
                    recordNumber: rn, isBaseRecord: false,
                    baseRecordNumber: rec.baseFileReference & mask
                ))
            } else {
                summaries.append(InUseRecordSummary(
                    recordNumber: rn, isBaseRecord: true, baseRecordNumber: nil
                ))
            }
        }
        let reachable = try await reachableSet(in: volume)
        let result = MFTConsistency.classifyInUseRecords(summaries, reachable: reachable)
        XCTAssertTrue(
            result.leakedExtensions.isEmpty,
            "post-delete classifier must report zero leaked extensions; got \(result.leakedExtensions.sorted())",
            file: file, line: line
        )
    }

    /// $I30-reachability set from root (record 5), mirroring `orphans`.
    private func reachableSet(in volume: Volume) async throws -> Set<UInt64> {
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
        return reachable
    }

    // MARK: - AC-7 / AC-3: delete frees extension records AND their clusters

    func testDeleteMigratedFileFreesExtensionRecordsAndClusters() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // The migration baseline is the free count after the swiss-cheese
        // carve but before writeFile (the carve permanently strands ~half the
        // free space; the delete only reclaims what writeFile allocated). The
        // delete must return us EXACTLY to this point — ALL migrated clusters
        // back, none over- or under-freed.
        guard let (rn, freeBeforeWrite) =
            try await driveDataOverflow(volume: volume, named: "del-migrated.bin") else {
            throw XCTSkip("small.img has too little free space to fragment for the overflow")
        }
        guard try await didMigrate(rn, in: volume) else {
            throw XCTSkip("could not force $DATA-migration on small.img for delete test")
        }

        let extRecords = try await extensionRecords(for: rn, in: volume)
        XCTAssertFalse(extRecords.isEmpty, "precondition: migrated file must own >= 1 extension record")

        try await volume.deleteFile(at: rn)

        // (a) base record freed.
        let mft = await volume.mft()
        let base = try await mft.record(at: rn)
        XCTAssertFalse(base.isInUse, "base record \(rn) must be IN_USE=0 after delete")

        // (b) every extension record freed.
        for ext in extRecords {
            let er = try await mft.record(at: ext)
            XCTAssertFalse(er.isInUse, "extension record \(ext) must be IN_USE=0 after delete")
        }

        // (c) free-cluster count restored to the pre-write baseline — ALL
        //     migrated clusters returned (AC-3 cluster accounting).
        let afterFree = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            afterFree, freeBeforeWrite,
            "all migrated clusters must be reclaimed: pre-write \(freeBeforeWrite), after-delete \(afterFree)"
        )

        // (d) orphan + leaked-extension walk clean on reopen.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let leaked = try await orphans(in: reopen)
        XCTAssertTrue(leaked.isEmpty, "post-delete reopen must be orphan-free; got \(leaked.sorted().prefix(10))")
        try await assertNoLeakedExtensions(in: reopen)
    }

    // MARK: - AC-2: deleting one migrated file leaves another intact

    func testDeleteOneMigratedFileLeavesAnotherMigratedFileIntact() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Two migrated files. Migration needs a ~250-fragment runlist to exceed
        // the base record's ~752-byte slack, and the swiss-cheese carve strands
        // ~half the free space; on the 4 MiB small.img (~640 free clusters)
        // fitting TWO independent migrations does not fit. We still attempt it
        // (the second reuses A's fragmentation, no fresh carve) and XCTSkip
        // cleanly if the fixture can't host both — the per-record "don't free
        // the wrong record" guarantee is also covered by the leaked-extension
        // classifier tests in MFTConsistencyTests.
        guard let (rnA, _) =
            try await driveDataOverflow(volume: volume, named: "keep.bin", clusters: 260) else {
            throw XCTSkip("small.img has too little free space for the first overflow")
        }
        guard let (rnB, _) =
            try await driveDataOverflow(volume: volume, named: "drop.bin", clusters: 260, fragment: false) else {
            throw XCTSkip("small.img cannot fit a second migrated file alongside the first")
        }
        guard try await didMigrate(rnA, in: volume), try await didMigrate(rnB, in: volume) else {
            throw XCTSkip("could not force two concurrent $DATA-migrations on small.img")
        }

        let keepExts = try await extensionRecords(for: rnA, in: volume)
        XCTAssertFalse(keepExts.isEmpty, "the kept file must own an extension record")
        let keepContent = try await volume.readFile(at: rnA)

        // Delete only file B.
        try await volume.deleteFile(at: rnB)

        // File A's base + extension(s) must remain IN_USE and read unchanged.
        let mft = await volume.mft()
        let baseA = try await mft.record(at: rnA)
        XCTAssertTrue(baseA.isInUse, "the kept file's base record \(rnA) must stay IN_USE")
        for ext in keepExts {
            let extInUse = try await mft.record(at: ext).isInUse
            XCTAssertTrue(extInUse, "the kept file's extension record \(ext) must stay IN_USE")
        }
        let reread = try await volume.readFile(at: rnA)
        XCTAssertEqual(reread, keepContent, "deleting the other file must not corrupt the kept file's data")

        // And the kept file survives a reopen byte-identical.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let reopenContent = try await reopen.readFile(at: rnA)
        XCTAssertEqual(reopenContent, keepContent, "kept file must read identically after reopen")
        try await assertNoLeakedExtensions(in: reopen)
    }

    // MARK: - AC-4: delete + freeExtensionRecord are idempotent (no double-free)

    func testDeleteMigratedFileIsIdempotent() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        guard let (rn, _) =
            try await driveDataOverflow(volume: volume, named: "idem.bin") else {
            throw XCTSkip("small.img has too little free space to fragment for the overflow")
        }
        guard try await didMigrate(rn, in: volume) else {
            throw XCTSkip("could not force $DATA-migration on small.img for idempotency test")
        }
        let extRecords = try await extensionRecords(for: rn, in: volume)
        XCTAssertFalse(extRecords.isEmpty, "precondition: migrated file must own >= 1 extension record")

        try await volume.deleteFile(at: rn)
        let freeAfterFirst = try await volume.allocationStats().freeClusters

        // A second full deleteFile short-circuits on the BASE record's isInUse
        // guard, so the meaningful observable is the BASE record's sequence
        // number. The first delete clears IN_USE and bumps the sequence once;
        // capture it now.
        let mftAfterFirst = await volume.mft()
        let baseAfterFirst = try await mftAfterFirst.record(at: rn)
        XCTAssertFalse(baseAfterFirst.isInUse, "base record \(rn) must be IN_USE=0 after the first delete")
        let baseSeqAfterFirstDelete = baseAfterFirst.sequenceNumber

        // Second delete must not throw and must not change the free count.
        try await volume.deleteFile(at: rn)
        let freeAfterSecond = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfterSecond, freeAfterFirst,
            "a second deleteFile must be a no-op (no double-free): \(freeAfterFirst) → \(freeAfterSecond)"
        )

        // The free-cluster count is a weak signal (Bitmap.free is bit-idempotent
        // so re-freeing clusters is invisible to it). The base record's SEQUENCE
        // NUMBER is the observable that bites: the base isInUse guard must
        // short-circuit the second delete so the sequence is NOT bumped again.
        // (Removing the guard rewrites the base and bumps it a second time.)
        let baseAfterSecond = try await mftAfterFirst.record(at: rn)
        XCTAssertFalse(baseAfterSecond.isInUse, "base record \(rn) must remain IN_USE=0 after the second delete")
        XCTAssertEqual(
            baseAfterSecond.sequenceNumber, baseSeqAfterFirstDelete,
            "second delete must be a clean no-op: the base isInUse guard must prevent a second sequence bump"
        )

        // freeExtensionRecord on an already-freed extension is also a no-op.
        try await volume.freeExtensionRecord(at: extRecords[0])
        let freeAfterExt = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfterExt, freeAfterSecond,
            "freeExtensionRecord on an already-freed extension must not change the free count"
        )
    }

    // MARK: - AC-9: freeExtensionRecord frees clusters + slot, then idempotent

    func testFreeExtensionRecordFreesClustersAndSlotThenIdempotent() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        guard let (rn, _) =
            try await driveDataOverflow(volume: volume, named: "freeext.bin") else {
            throw XCTSkip("small.img has too little free space to fragment for the overflow")
        }
        guard try await didMigrate(rn, in: volume) else {
            throw XCTSkip("could not force $DATA-migration on small.img for freeExtensionRecord test")
        }
        guard let extRN = try await findExtensionRecord(for: rn, in: volume) else {
            return XCTFail("expected an extension record for migrated file \(rn)")
        }

        // Sum the extension record's own non-resident allocation up front.
        let mft = await volume.mft()
        let extRec = try await mft.record(at: extRN)
        XCTAssertTrue(extRec.isInUse, "precondition: extension record must start IN_USE")
        var extClusters: UInt64 = 0
        for attr in try extRec.attributes() {
            if case let .nonResident(_, _, _, _, _, _, _, extents) = attr.value {
                for e in extents { extClusters += e.clusterCount }
            }
        }
        XCTAssertGreaterThan(extClusters, 0, "the migrated extension must hold non-resident clusters")

        let freeBefore = try await volume.allocationStats().freeClusters
        try await volume.freeExtensionRecord(at: extRN)

        // Slot freed; capture the post-first-free sequence number. The first
        // free clears IN_USE and bumps the sequence exactly once.
        let extRecAfterFirst = try await mft.record(at: extRN)
        XCTAssertFalse(extRecAfterFirst.isInUse,
                       "extension record \(extRN) must be IN_USE=0 after freeExtensionRecord")
        let seqAfterFirstFree = extRecAfterFirst.sequenceNumber
        // Free count rose by exactly the extension's allocation.
        let freeAfter = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfter, freeBefore + extClusters,
            "freeExtensionRecord must return exactly the extension's \(extClusters) clusters"
        )

        // Idempotent second call. The free-cluster count is a weak signal here —
        // Bitmap.free is bit-idempotent, so re-freeing already-clear clusters is
        // invisible to it. The SEQUENCE NUMBER is the observable that bites: the
        // isInUse guard must short-circuit the second call so the sequence is
        // NOT bumped a second time. (Removing the guard rewrites the record and
        // bumps the sequence again — exactly what we assert against.)
        try await volume.freeExtensionRecord(at: extRN)
        let extRecAfterSecond = try await mft.record(at: extRN)
        XCTAssertFalse(extRecAfterSecond.isInUse,
                       "extension record \(extRN) must remain IN_USE=0 after a second freeExtensionRecord")
        XCTAssertEqual(
            extRecAfterSecond.sequenceNumber, seqAfterFirstFree,
            "second free must be a no-op: the isInUse guard must prevent a second sequence bump (no double-free)"
        )
        let freeAfterSecond = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfterSecond, freeAfter,
            "a second freeExtensionRecord must be a no-op (no double-free)"
        )
    }

    // MARK: - allAttributesOf surfaces migrated $DATA at the exact written size

    /// The FSKit target's `makeFreshAttributes` reads a migrated file's size via
    /// `coreVolume.allAttributesOf(recordNumber:)`. That target can't be
    /// swift-tested, so this is its indirect proof: force a $DATA migration with a
    /// known byte length, then confirm `allAttributesOf` surfaces the unnamed
    /// $DATA from the extension record AND that its `realSize` equals exactly the
    /// bytes written. A wrong size here is precisely the bug FSKit would report.
    func testAllAttributesOfReturnsMigratedDataWithCorrectSize() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let clusters: UInt64 = 260
        guard let (rn, _) = try await driveDataOverflow(
            volume: volume, named: "size-migrated.bin", clusters: clusters
        ) else {
            throw XCTSkip("small.img has too little free space to fragment for the overflow")
        }
        guard try await didMigrate(rn, in: volume) else {
            throw XCTSkip("could not force $DATA-migration on small.img for size test")
        }

        // driveDataOverflow writes exactly `clusters * bytesPerCluster - 17`
        // bytes — recompute the same way so the assertion tracks the helper.
        let expectedSize = UInt64(Int(clusters * UInt64(volume.bytesPerCluster)) - 17)

        // The base record alone does NOT carry the unnamed $DATA after migration
        // (it lives in the extension via $ATTRIBUTE_LIST) — that's the whole
        // point of the $ATTRIBUTE_LIST-aware read path FSKit now depends on.
        let mft = await volume.mft()
        let baseOnly = try await mft.record(at: rn).attributes()
        XCTAssertFalse(
            baseOnly.contains { $0.type == .data && $0.nameOrEmpty == "" },
            "precondition: post-migration the base record must NOT hold the unnamed $DATA itself"
        )

        // allAttributesOf walks $ATTRIBUTE_LIST into the extension record and
        // surfaces the migrated unnamed $DATA.
        let all = try await volume.allAttributesOf(recordNumber: rn)
        guard let dataAttr = all.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else {
            return XCTFail("allAttributesOf must surface the migrated unnamed $DATA from the extension record")
        }
        guard case let .nonResident(_, _, _, _, _, realSize, _, _) = dataAttr.value else {
            return XCTFail("a migrated $DATA must be non-resident")
        }
        XCTAssertEqual(
            realSize, expectedSize,
            "the $DATA size FSKit's makeFreshAttributes reads must equal the bytes written: expected \(expectedSize), got \(realSize)"
        )
    }

    // MARK: - truncate on a migrated file fails cleanly without mutating state

    /// truncate on a migrated file (base carries $ATTRIBUTE_LIST, unnamed $DATA
    /// in an extension record) must reject with a clean `unsupportedFeature` —
    /// NOT a false `corruptOnDisk` — for every newSize including 0, and must do
    /// so BEFORE freeing any clusters or writing anything. Proves the guard bails
    /// ahead of any mutation.
    func testTruncateMigratedFileThrowsCleanUnsupported() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        guard let (rn, _) = try await driveDataOverflow(
            volume: volume, named: "trunc-migrated.bin"
        ) else {
            throw XCTSkip("small.img has too little free space to fragment for the overflow")
        }
        guard try await didMigrate(rn, in: volume) else {
            throw XCTSkip("could not force $DATA-migration on small.img for truncate test")
        }

        // Capture the exact pre-truncate state the guard must preserve: the
        // original bytes (read via the migrated $DATA) and the free-cluster count.
        let originalContent = try await volume.readFile(at: rn)
        XCTAssertFalse(originalContent.isEmpty, "precondition: migrated file must have content")
        let freeBefore = try await volume.allocationStats().freeClusters

        // Both a non-zero shrink AND 0 must throw unsupportedFeature, never
        // corruptOnDisk (the latter would mean the lacks-$DATA guard misfired on
        // a healthy migrated file).
        let nonZeroShrink = UInt64(max(1, originalContent.count / 2))
        for target: UInt64 in [nonZeroShrink, 0] {
            await XCTAssertThrowsErrorAsync(
                try await volume.truncate(at: rn, newSize: target),
                "truncate(newSize: \(target)) on a migrated file must throw"
            ) { error in
                guard case NTFSError.unsupportedFeature = error else {
                    if case NTFSError.corruptOnDisk = error {
                        XCTFail("truncate(newSize: \(target)) threw corruptOnDisk on a healthy migrated file; must be unsupportedFeature")
                    } else {
                        XCTFail("truncate(newSize: \(target)) threw \(error); expected unsupportedFeature")
                    }
                    return
                }
            }
        }

        // Nothing was mutated: no clusters freed and the file still reads back its
        // original bytes via the migrated $DATA — the guard bailed pre-mutation.
        let freeAfter = try await volume.allocationStats().freeClusters
        XCTAssertEqual(
            freeAfter, freeBefore,
            "rejected truncate must not free any clusters: before \(freeBefore), after \(freeAfter)"
        )
        let afterContent = try await volume.readFile(at: rn)
        XCTAssertEqual(
            afterContent, originalContent,
            "rejected truncate must leave the migrated file's bytes unchanged"
        )
    }
}

/// Async-throwing assertion helper — XCTest's `XCTAssertThrowsError` is sync, so
/// awaiting expressions need this wrapper to capture + inspect the thrown error.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error to be thrown but none was" : message, file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
