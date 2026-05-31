import XCTest
@testable import NTFSCore

/// v0.7.1 — directory `$INDEX_ALLOCATION` locality coverage.
///
/// ## Why this file exists
///
/// A directory's index nodes ("INDX blocks", 4 KiB each) live in the
/// non-resident `$INDEX_ALLOCATION` (type 0xA0, name `$I30`) attribute, whose
/// runlist lists the disk clusters holding them. Pre-v0.7.1, every new INDX
/// block is allocated via `allocateClusters(1)` using the GLOBAL next-fit hint
/// (`_allocHint`), shared with file `$DATA` allocation. During a `cp -r`, file
/// `$DATA` clusters get allocated *between* consecutive INDX-block allocations,
/// so INDX blocks scatter on disk → one runlist extent per block → the runlist
/// grows ~linearly with file count and overflows the 1 KB MFT record at
/// ~8,000 files (forcing an `$ATTRIBUTE_LIST` migration). Real NTFS drivers
/// allocate each directory's INDX blocks contiguously (per-directory locality)
/// to avoid this.
///
/// ## What this file owns
///
/// AC-0 (THIS WORKER): make the fragmentation OBSERVABLE and MEASURE the
/// pre-fix baseline as hard fact, BEFORE any fix lands. `testPreFix...`
/// drives a fresh subdirectory to thousands of entries (interleaved with
/// per-file `$DATA` writes that reproduce the real `cp -r` allocation order)
/// and asserts the resulting `$INDEX_ALLOCATION` extent count is LARGE — the
/// pre-fix fragmentation made concrete.
///
/// ## Reusable harness (later AC-3/AC-4/AC-5 workers extend THIS file)
///
/// The helpers below are deliberately general so the post-fix tests can reuse
/// them to assert the OPPOSITE (few extents, no `$ATTRIBUTE_LIST` migration):
///   * `freshFormattedVolume(sizeMiB:)` — format + open a fresh writable image,
///     auto-deleting the tmp file at teardown.
///   * `makeSubdirectory(in:volume:named:)` — create a fresh subdirectory.
///   * `driveDirectory(volume:dirRN:entryCount:namePrefix:bytesPerFile:)` —
///     create N files under a directory, each with non-resident `$DATA`,
///     interleaving file-data and INDX-block allocations the way `cp -r` does.
///   * `indexAllocationExtentCount(volume:dirRN:)` — merged `$I30` non-sparse
///     extent count (the fragmentation metric).
///   * `directoryMigratedToAttributeList(volume:dirRN:)` — whether the base
///     MFT record carries an `$ATTRIBUTE_LIST` (the `$I30` cap fired).
final class DirectoryIndexLocalityTests: XCTestCase {

    // MARK: - Reusable harness

    /// Format a FRESH writable image in a tmp file and open it. The image is
    /// sized generously (sparse on macOS, so logical size is cheap) so it can
    /// hold thousands of files plus their `$DATA` and index. Registers a
    /// teardown block to delete the tmp file.
    ///
    /// Returns the opened `Volume` (writable; the in-process formatter holds
    /// the device, so we reuse the same handle for read+write).
    func freshFormattedVolume(sizeMiB: Int = 512, label: String = "LOCALITY") async throws -> Volume {
        let tmpDir = FileManager.default.temporaryDirectory
        let path = tmpDir
            .appendingPathComponent("dir-index-locality-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()

        // Auto-clean the tmp file regardless of pass/fail.
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await device.size()
        try await Volume.formatNTFS(
            device: device,
            deviceSizeBytes: size,
            label: label,
            volumeSerial: 0x0123_4567_89AB_CDEF
        )
        // The in-process writer holds the fd; reuse it for the writable Volume.
        return try await Volume(device: device)
    }

    /// Create a fresh subdirectory under `parentRN` (root by default). Returns
    /// the new directory's MFT record number.
    func makeSubdirectory(
        in parentRN: UInt64 = 5, volume: Volume, named name: String
    ) async throws -> UInt64 {
        try await volume.createFile(named: name, inDirectory: parentRN, isDirectory: true)
    }

    /// Drive directory `dirRN` to `entryCount` entries the way a real `cp -r`
    /// does: for each file, create its MFT entry (which may allocate a new INDX
    /// block in the parent's `$I30`) and THEN write its non-resident `$DATA`
    /// (which allocates content clusters via the SAME global next-fit hint).
    /// Interleaving file-data allocations between INDX-block allocations is
    /// EXACTLY what scatters the INDX blocks pre-fix — without per-file
    /// non-resident `$DATA` nothing interleaves and even the unfixed allocator
    /// wouldn't fragment, so this is load-bearing for a meaningful baseline.
    ///
    /// `bytesPerFile` defaults to one cluster (4096) — the minimum that forces
    /// a non-resident `$DATA` allocation. Returns the count of files actually
    /// created (stops early and returns the partial count on `outOfSpace` /
    /// `unsupportedFeature`).
    @discardableResult
    func driveDirectory(
        volume: Volume,
        dirRN: UInt64,
        entryCount: Int,
        namePrefix: String = "f",
        bytesPerFile: Int = 4096
    ) async throws -> Int {
        // One reusable cluster-sized payload; chunked back on each write.
        let payload = Data(repeating: 0xAB, count: bytesPerFile)
        var created = 0
        for i in 0..<entryCount {
            let name = String(format: "\(namePrefix)-%06d.bin", i)
            let fileRN: UInt64
            do {
                fileRN = try await volume.createFile(named: name, inDirectory: dirRN)
            } catch NTFSError.outOfSpace { break }
              catch NTFSError.unsupportedFeature { break }

            // Write one cluster of non-resident $DATA so the content allocation
            // interleaves between this and the next INDX-block allocation.
            var remaining = bytesPerFile
            do {
                try await volume.writeFile(at: fileRN, totalSize: UInt64(bytesPerFile)) {
                    if remaining == 0 { return Data() }
                    let take = min(remaining, payload.count)
                    remaining -= take
                    return payload.prefix(take)
                }
            } catch NTFSError.outOfSpace { break }
              catch NTFSError.unsupportedFeature { break }
            created += 1
        }
        return created
    }

    /// Non-sparse extent count of directory `dirRN`'s merged
    /// `$INDEX_ALLOCATION:$I30` runlist. This is the fragmentation metric: it
    /// equals the number of distinct contiguous INDX-block runs on disk. Reads
    /// via the `$ATTRIBUTE_LIST`-aware merged view (`allAttributesOf`) so a
    /// migrated directory's index is counted across all extensions. Returns 0
    /// if the directory's index is still resident in `$INDEX_ROOT` (no
    /// `$INDEX_ALLOCATION` yet).
    func indexAllocationExtentCount(volume: Volume, dirRN: UInt64) async throws -> Int {
        let attrs = try await volume.allAttributesOf(recordNumber: dirRN)
        guard let ia = attrs.first(where: {
            $0.type == .indexAllocation && $0.nameOrEmpty == "$I30"
        }) else {
            return 0
        }
        guard case let .nonResident(_, _, _, _, _, _, _, extents) = ia.value else {
            return 0
        }
        return extents.filter { !$0.isSparse }.count
    }

    /// Whether directory `dirRN`'s BASE MFT record carries a `$ATTRIBUTE_LIST`
    /// (type 0x20) — i.e. the `$INDEX_ALLOCATION` overflow/migration mechanism
    /// fired. Reads the base record's OWN attributes (NOT the merged
    /// `allAttributesOf` view) because the merged view hides the
    /// `$ATTRIBUTE_LIST` itself; we want to detect its presence.
    func directoryMigratedToAttributeList(volume: Volume, dirRN: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        let base = try await mft.record(at: dirRN)
        let attrs = try base.attributes()
        return attrs.contains { $0.rawType == AttributeType.attributeList.rawValue }
    }

    // MARK: - AC-3: post-fix locality payoff

    /// AC-3 payoff. Drives a fresh subdirectory to the SAME 4,000-entry scale
    /// as the AC-0 baseline — with the SAME per-file non-resident `$DATA`
    /// interleave (load-bearing: it reproduces the real `cp -r` allocation
    /// order that scattered the index pre-fix) — and asserts the OPPOSITE of
    /// the baseline:
    ///   1. the directory's `$INDEX_ALLOCATION` runlist has FEW extents (≤ 10),
    ///      because the per-directory locality allocator places consecutive
    ///      INDX blocks contiguously in an index lane away from the `$DATA`
    ///      front, so the runs coalesce; AND
    ///   2. the directory did NOT migrate to `$ATTRIBUTE_LIST` — the `$I30`
    ///      overflow/cap mechanism never fires, because a coalesced runlist is
    ///      a handful of bytes and fits the base MFT record forever.
    ///
    /// Scale choice: identical to the baseline — 4,000 full createFile + 4 KiB
    /// non-resident `$DATA` writes. The assertion is the inverse of AC-0's.
    ///
    // MEASURED PRE-FIX (v0.7.1, unfixed code): 222 extents at 4000 entries on a 512 MiB image
    //   (the directory ALSO migrated to $ATTRIBUTE_LIST — the $I30 cap mechanism fired,
    //   confirming the runlist outgrew the 1 KB base MFT record exactly as the brief predicts).
    // MEASURED POST-FIX (v0.7.1, locality allocator): 1 extent at 4000 entries on a 512 MiB image,
    //   NO $ATTRIBUTE_LIST migration. The per-directory locality hint + high index lane
    //   (indexChunkClusters=256, upper-25% lane base) keeps every INDX block contiguous, so the
    //   whole directory's $I30 runlist coalesces into a SINGLE extent (down from 222 pre-fix).
    func testLargeDirectoryIndexStaysContiguous() async throws {
        let volume = try await freshFormattedVolume(sizeMiB: 512)
        let dirRN = try await makeSubdirectory(volume: volume, named: "bigdir")

        let entryTarget = 4000
        let created = try await driveDirectory(
            volume: volume,
            dirRN: dirRN,
            entryCount: entryTarget,
            namePrefix: "file",
            bytesPerFile: 4096
        )

        XCTAssertGreaterThan(
            created, 1000,
            "harness must create a substantial number of entries to demonstrate locality; got \(created)"
        )

        let extents = try await indexAllocationExtentCount(volume: volume, dirRN: dirRN)
        let migrated = try await directoryMigratedToAttributeList(volume: volume, dirRN: dirRN)

        print("""
            === AC-3 POST-FIX INDEX LOCALITY PAYOFF ===
            image size:                 512 MiB
            entries created:            \(created) (target \(entryTarget))
            $INDEX_ALLOCATION extents:  \(extents)
            migrated to $ATTRIBUTE_LIST: \(migrated)
            ===========================================
            """)

        // (1) The per-directory locality allocator keeps consecutive INDX
        //     blocks contiguous → the runlist coalesces to a handful of
        //     extents (down from the measured 222 pre-fix).
        XCTAssertLessThanOrEqual(
            extents, 10,
            """
            POST-FIX expects FEW $INDEX_ALLOCATION extents (≤ 10) from the \
            per-directory locality allocator coalescing consecutive INDX \
            blocks; measured \(extents) extents at \(created) entries (pre-fix \
            was 222). If this is large, the locality hint/lane isn't keeping \
            the index contiguous.
            """
        )

        // (2) A coalesced runlist never overflows the base MFT record, so the
        //     $I30 cap/migration mechanism must NOT fire at this scale.
        XCTAssertFalse(
            migrated,
            """
            POST-FIX expects NO $ATTRIBUTE_LIST migration at \(created) entries \
            — a contiguous index runlist is a few bytes and fits the base MFT \
            record forever. Migration firing means the runlist still grew large.
            """
        )
    }

    // MARK: - AC-4 / AC-7: fragmented-volume graceful degradation

    /// Swiss-cheese fragmentation of the volume's free space: allocate every
    /// free cluster as a 1-cluster extent (up to a cap), then free every other
    /// one. This heavily fragments the (low) region it covers, so as `$DATA`
    /// fills the index lane the allocator's private `indexChunkClusters` (256)
    /// contiguous probe fails and `allocateIndexClusters(near:)` is driven down
    /// its single-cluster degrade leaf (`findFreeRun(256) → findFreeRun(1)`).
    /// (The default `cap` leaves the upper free region intact, so the first few
    /// INDX blocks may still land contiguously in the upper-25% lane before the
    /// degrade path takes over — the multi-extent result below proves it ran.)
    ///
    /// Mirrors `MultiExtensionIndexAllocationTests.fragmentFreeSpace` (that
    /// helper is `private` to its file, so we re-declare it here rather than
    /// importing it). Returns the count of single-cluster holes punched, for
    /// diagnostics.
    @discardableResult
    func fragmentFreeSpace(_ volume: Volume, cap: Int = 8192) async throws -> Int {
        var singles: [Extent] = []
        while let e = try? await volume.allocateClusters(1) {
            singles.append(e)
            if singles.count > cap { break }
        }
        var holes = 0
        for (i, e) in singles.enumerated() where i % 2 == 0 {
            try await volume.freeClusters(e)
            holes += 1
        }
        return holes
    }

    /// AC-4 / AC-7 — graceful degradation on a fragmented volume.
    ///
    /// Fragment the volume's free space into a swiss-cheese pattern so NO
    /// 256-cluster contiguous run survives, then drive a directory's index
    /// non-resident and grow it across several INDX blocks. With locality
    /// unable to find a contiguous chunk, `allocateIndexClusters(near:)` must
    /// degrade to the single-cluster fallback (`findFreeRun(1)`) — exactly
    /// today's `allocateClusters(1)` behavior — and the directory must STILL
    /// grow correctly with no crash/corruption.
    ///
    /// Assertions:
    ///   1. the directory's `$INDEX_ALLOCATION` runlist has MULTIPLE extents
    ///      (degrade path engaged — locality could not keep it to 1 extent,
    ///      because the single-cluster fallback hands out scattered holes);
    ///   2. every created file enumerates back AND its `$DATA` reads back to
    ///      the written length (no structural corruption from the fallback).
    ///
    /// AC-4 also requires the PR #35 multi-extension `$ATTRIBUTE_LIST` fallback
    /// to keep working for the pathological case. That mechanism is proven
    /// end-to-end and unchanged by `MultiExtensionIndexAllocationTests`
    /// (testSecondMigrationAddsAdditionalExtension, …TransactionalFailure,
    /// …SpecConformantBytes, …VerifyDeepClean) — this test does not re-derive
    /// it; it proves the single-cluster degrade chain that sits BELOW the
    /// migration fallback.
    ///
    /// OBSERVED (64 MiB swiss-cheese, 1,500 entries): the fragmented runlist
    /// reached ~83 extents AND the directory migrated to `$ATTRIBUTE_LIST` —
    /// i.e. on a genuinely pathological volume BOTH the single-cluster degrade
    /// chain AND the PR #35 multi-extension fallback engage organically, while
    /// the directory still grows correctly and reads back. (Contrast the AC-3
    /// payoff test on a healthy 512 MiB volume: 1 extent, no migration.)
    func testFragmentedVolumeFallsBackAndStillGrows() async throws {
        // Smaller image so the swiss-cheese fragmentation covers essentially
        // all free space (no 256-run survives anywhere) within the cap.
        let volume = try await freshFormattedVolume(sizeMiB: 64, label: "FRAGFB")

        let holes = try await fragmentFreeSpace(volume)
        XCTAssertGreaterThan(
            holes, 256,
            "fragmentation must punch enough holes that no 256-cluster run survives; punched \(holes)"
        )

        let dirRN = try await makeSubdirectory(volume: volume, named: "fragdir")

        // Drive enough entries to push the index non-resident and grow it
        // across several INDX blocks. Resident $DATA (bytesPerFile=0 would stay
        // resident); use a small non-resident payload so each file consumes a
        // hole and the index is forced to grow from the remaining scattered
        // holes. Stops early on outOfSpace (the fragmented 64 MiB image is
        // deliberately tight) — the partial count is fine for the degrade proof.
        let created = try await driveDirectory(
            volume: volume,
            dirRN: dirRN,
            entryCount: 1500,
            namePrefix: "frag",
            bytesPerFile: 4096
        )
        XCTAssertGreaterThan(
            created, 200,
            "must create enough entries to force multi-block index growth; got \(created)"
        )

        let extents = try await indexAllocationExtentCount(volume: volume, dirRN: dirRN)
        let migrated = try await directoryMigratedToAttributeList(volume: volume, dirRN: dirRN)

        print("""
            === AC-4/AC-7 FRAGMENTED-VOLUME DEGRADE ===
            image size:                 64 MiB (swiss-cheese fragmented)
            holes punched:              \(holes)
            entries created:            \(created)
            $INDEX_ALLOCATION extents:  \(extents)
            migrated to $ATTRIBUTE_LIST: \(migrated)
            ===========================================
            """)

        // (1) Degrade path engaged: the index could not be kept to 1 extent on
        //     a fully-fragmented volume, so the single-cluster fallback produced
        //     a multi-extent runlist. (>1 proves the fallback chain ran without
        //     crashing — contrast the contiguous test's ==1.)
        XCTAssertGreaterThan(
            extents, 1,
            """
            On a swiss-cheese-fragmented volume the locality allocator must \
            degrade to single-cluster fallback, producing a MULTI-extent \
            $INDEX_ALLOCATION runlist; measured \(extents) extents at \(created) \
            entries. ==1 would mean a contiguous chunk survived fragmentation \
            (test setup failed to fragment).
            """
        )

        // (2) No corruption: every created file enumerates and reads back.
        let entries = try await volume.enumerate(directory: dirRN)
        let nonDosNames = Set(
            entries.filter { $0.fileName.namespace != .dos }.map { $0.fileName.name }
        )
        for i in 0..<created {
            let name = String(format: "frag-%06d.bin", i)
            XCTAssertTrue(
                nonDosNames.contains(name),
                "fragmented-grow file '\(name)' must still enumerate (index grew correctly under fallback)"
            )
        }
        // Spot-check readback on a sample so we don't read 1000s of files.
        let sampleIndices = stride(from: 0, to: created, by: max(1, created / 25))
        for i in sampleIndices {
            let name = String(format: "frag-%06d.bin", i)
            guard let entry = entries.first(where: {
                $0.fileName.namespace != .dos && $0.fileName.name == name
            }) else {
                XCTFail("sample file '\(name)' missing from enumeration")
                continue
            }
            let bytes = try await volume.readFile(at: entry.recordNumber)
            XCTAssertEqual(
                bytes.count, 4096,
                "sample file '\(name)' $DATA must read back to its written length under the fallback"
            )
        }
    }

    // MARK: - AC-5: no cluster leak (deep-audit + orphan reachability)

    /// Reachability orphan walk: IN_USE user base records (rn >= 16, not an
    /// extension) that are NOT reachable from root via `enumerate`. Mirrors
    /// `MultiExtensionIndexAllocationTests.orphans` (private there). A leaked
    /// extension record or a dangling INDX-referenced child would surface here.
    func orphans(in volume: Volume, maxRN: UInt64 = 4096) async throws -> Set<UInt64> {
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

    /// AC-5 (no leak on delete). Drive a directory to a few thousand entries
    /// (locality-grown, multi-INDX-block), then delete every file and the now-
    /// empty directory, and assert the whole-volume deep audit is clean with
    /// zero free-but-referenced / double-allocated clusters and no orphans.
    ///
    /// Because every INDX cluster is marked in `$Bitmap` only at build+splice
    /// time (allocate-on-use — no reserved tail), `deleteFile` frees exactly
    /// what was referenced and nothing leaks. The pre/post free-cluster-count
    /// comparison is the direct INDX-leak canary (the `$DATA`-focused audit
    /// catches double-alloc/free-but-referenced; the count delta catches a
    /// silently-leaked INDX tail).
    ///
    /// Scale: 2,500 entries on a 256 MiB image — enough to grow the index
    /// across several INDX blocks (verified via extent count) without the cost
    /// of the 4,000-entry payoff test.
    func testNoLeakAfterDeletingLocalityGrownDirectory() async throws {
        let volume = try await freshFormattedVolume(sizeMiB: 256, label: "NOLEAKD")

        let bmBefore = try await volume.bitmap()
        let freeBefore = bmBefore.freeClusterCount

        let dirRN = try await makeSubdirectory(volume: volume, named: "deldir")
        let entryTarget = 2500
        let created = try await driveDirectory(
            volume: volume,
            dirRN: dirRN,
            entryCount: entryTarget,
            namePrefix: "del",
            bytesPerFile: 4096
        )
        XCTAssertGreaterThan(created, 500, "need a substantial directory to grow the index; got \(created)")

        // Confirm the index actually grew non-resident (this test is only
        // meaningful if there ARE INDX clusters to leak).
        let extentsGrown = try await indexAllocationExtentCount(volume: volume, dirRN: dirRN)
        XCTAssertGreaterThan(
            extentsGrown, 0,
            "directory must have a non-resident $INDEX_ALLOCATION (INDX clusters to free); extents=\(extentsGrown)"
        )

        // Delete every file, then the now-empty directory.
        let entries = try await volume.enumerate(directory: dirRN)
        for e in entries where e.fileName.namespace != .dos {
            try await volume.deleteFile(at: e.recordNumber)
        }
        try await volume.deleteFile(at: dirRN)

        // (1) Free-cluster count must return to baseline (no leaked INDX or
        //     $DATA tail). This is the direct INDX-leak canary.
        let bmAfter = try await volume.bitmap()
        let freeAfter = bmAfter.freeClusterCount
        print("""
            === AC-5 NO-LEAK-ON-DELETE ===
            entries created/deleted:    \(created)
            $INDEX_ALLOCATION extents (pre-delete): \(extentsGrown)
            free clusters before build: \(freeBefore)
            free clusters after delete: \(freeAfter)
            ==============================
            """)
        XCTAssertEqual(
            freeAfter, freeBefore,
            """
            free-cluster count must return to baseline after deleting the whole \
            locality-grown directory — any shortfall is a leaked INDX/$DATA tail. \
            before=\(freeBefore), after=\(freeAfter), leaked=\(Int64(freeBefore) - Int64(freeAfter)).
            """
        )

        // (2) Whole-volume deep audit clean.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(
            sweep.isClean,
            """
            deep audit must be clean after delete; got \
            freeButReferenced=\(sweep.freeButReferencedClusters), \
            outOfRange=\(sweep.outOfRangeClusters), \
            doubleAllocated=\(sweep.doubleAllocatedClusters), \
            unreadable=\(sweep.unreadableRecords.count)
            """
        )
        XCTAssertEqual(sweep.freeButReferencedClusters, 0, "0 free-but-referenced clusters")
        XCTAssertEqual(sweep.doubleAllocatedClusters, 0, "0 double-allocated clusters")

        // (3) No orphans (the deleted directory + children left nothing
        //     IN_USE-but-unreachable).
        let orphanSet = try await orphans(in: volume)
        XCTAssertTrue(
            orphanSet.isEmpty,
            "no orphans after deleting the locality-grown directory; got \(orphanSet.sorted())"
        )
    }

    /// AC-5 (no leak on aborted growth — crash-simulating). Drive a directory
    /// partway so it's locality-grown (several INDX blocks), then simulate an
    /// abort DURING further index growth and assert disk consistency.
    ///
    /// MECHANISM: `_setCreateFileFaultHook(.afterI30CommitBeforeReturn)`.
    /// Per Volume.swift, `.afterI30CommitBeforeReturn` throws AFTER
    /// `insertIntoParentI30` has committed (the leaf-split/promote path that
    /// allocates+splices the new INDX block runs INSIDE `insertIntoParentI30`,
    /// and marks each INDX cluster in `$Bitmap` at build+splice time) but
    /// BEFORE `createFile` returns. This faithfully represents "abort mid-
    /// directory-growth": the index has just grown (a new INDX cluster may have
    /// been allocated and spliced into the runlist) and we crash before the
    /// operation completes. The allocate-on-use discipline (AC-2) guarantees no
    /// reserved-but-unmarked chunk exists, so the on-disk state must remain
    /// consistent: 0 free-but-referenced, 0 double-allocated, no orphans, and
    /// the directory still fully enumerates.
    ///
    /// (We use the fault hook rather than a reopen-consistency proof because a
    /// fault point DOES land right after INDX growth — it is the more faithful
    /// "abort mid-growth" representation.)
    ///
    /// Scale: ~800 entries on a 256 MiB image — enough to be multi-INDX-block
    /// before the aborted create.
    func testNoLeakAfterAbortedDirectoryGrowth() async throws {
        let volume = try await freshFormattedVolume(sizeMiB: 256, label: "NOLEAKA")
        let dirRN = try await makeSubdirectory(volume: volume, named: "abortdir")

        // Drive partway so the index is locality-grown (multi-INDX-block).
        let created = try await driveDirectory(
            volume: volume,
            dirRN: dirRN,
            entryCount: 800,
            namePrefix: "ab",
            bytesPerFile: 4096
        )
        XCTAssertGreaterThan(created, 300, "directory must be locality-grown before abort; got \(created)")
        let extentsBefore = try await indexAllocationExtentCount(volume: volume, dirRN: dirRN)
        XCTAssertGreaterThan(
            extentsBefore, 0,
            "directory must have a non-resident $INDEX_ALLOCATION before the aborted growth"
        )

        // Snapshot the reachable name set pre-abort (data-loss canary).
        let entriesPre = try await volume.enumerate(directory: dirRN)
        let namesPre = Set(
            entriesPre.filter { $0.fileName.namespace != .dos }.map { $0.fileName.name }
        )

        // Install the fault hook: the NEXT createFile commits its $I30 entry
        // (running the INDX-growth allocate+splice), then throws before
        // returning — the crash-mid-growth window.
        await volume._setCreateFileFaultHook(.afterI30CommitBeforeReturn)
        var caught: Error?
        do {
            _ = try await volume.createFile(named: "ab-ABORT-MARKER.bin", inDirectory: dirRN)
        } catch {
            caught = error
        }
        await volume._setCreateFileFaultHook(nil)

        let err = try XCTUnwrap(caught, "the aborted createFile must throw at .afterI30CommitBeforeReturn")
        if case NTFSError.ioFailure(let desc) = err {
            XCTAssertTrue(
                desc.contains("afterI30CommitBeforeReturn"),
                "expected the afterI30CommitBeforeReturn fault; got: \(desc)"
            )
        } else {
            XCTFail("expected NTFSError.ioFailure from the fault hook; got: \(err)")
        }

        // (1) Whole-volume deep audit clean despite the mid-growth abort.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        print("""
            === AC-5 NO-LEAK-ON-ABORT ===
            entries before abort:       \(created)
            $INDEX_ALLOCATION extents:  \(extentsBefore)
            freeButReferenced:          \(sweep.freeButReferencedClusters)
            doubleAllocated:            \(sweep.doubleAllocatedClusters)
            =============================
            """)
        XCTAssertTrue(
            sweep.isClean,
            """
            deep audit must be clean after a mid-growth abort (allocate-on-use \
            leaves no reserved tail); got \
            freeButReferenced=\(sweep.freeButReferencedClusters), \
            outOfRange=\(sweep.outOfRangeClusters), \
            doubleAllocated=\(sweep.doubleAllocatedClusters), \
            unreadable=\(sweep.unreadableRecords.count)
            """
        )
        XCTAssertEqual(sweep.freeButReferencedClusters, 0, "0 free-but-referenced after abort")
        XCTAssertEqual(sweep.doubleAllocatedClusters, 0, "0 double-allocated after abort")

        // (2) No orphans introduced by the aborted growth.
        let orphanSet = try await orphans(in: volume)
        XCTAssertTrue(
            orphanSet.isEmpty,
            "no orphans after the aborted directory growth; got \(orphanSet.sorted())"
        )

        // (3) Data-loss canary: every name present pre-abort still enumerates
        //     (the abort neither dropped existing entries nor corrupted the
        //     index it had just grown).
        let entriesPost = try await volume.enumerate(directory: dirRN)
        let namesPost = Set(
            entriesPost.filter { $0.fileName.namespace != .dos }.map { $0.fileName.name }
        )
        let missing = namesPre.subtracting(namesPost)
        XCTAssertTrue(
            missing.isEmpty,
            "post-abort: all pre-abort entries must still enumerate; missing \(missing.sorted().prefix(5))"
        )
    }

    /// AC-5 (no leak on a mid-COMMIT leaf-split failure — the gap the Phase 4.5
    /// holistic review of PR #36 surfaced).
    ///
    /// `splitLeafAndPromote` does its device writes (LEFT/RIGHT leaves, any
    /// height-grow/cascade intermediates, the parent-record commit) AFTER the
    /// in-memory `computeParentRecordBytesForSplit` step. Pre-fix, a
    /// `device.write` that threw partway through that write sequence left the
    /// provisionally-allocated clusters (`newExtent` for the right-half leaf +
    /// any cascade extents) marked allocated in `$Bitmap` with nothing pointing
    /// at them — a silent cluster LEAK — and the original leaf trimmed to its
    /// left half (a half-rewritten index). The compute-step `catch` already
    /// freed `newExtent` on a *compute* failure; the *commit-sequence* failure
    /// had no such rollback.
    ///
    /// MECHANISM: `_setSplitLeafFaultHookAfterLeftLeaf` fires once, AFTER the
    /// destructive LEFT-leaf rewrite has hit disk but BEFORE the RIGHT-leaf
    /// write — exactly the worst-case window (leaf trimmed, clusters allocated,
    /// parent not yet committed). We drive a directory multi-INDX-block, arm the
    /// hook, then create files until one triggers a leaf split (which the hook
    /// aborts), and assert the post-abort on-disk state is pristine:
    ///   * free-cluster count is byte-for-byte restored (the direct LEAK canary:
    ///     pre-fix it would drop by ≥1 cluster — the never-freed `newExtent`);
    ///   * whole-volume deep audit clean — 0 free-but-referenced, 0
    ///     double-allocated (a restored extension referencing a freed cluster
    ///     would trip free-but-referenced);
    ///   * no orphans (the rollback leaves `i30Committed` false, so `createFile`
    ///     reclaims the child's MFT slot — a fully clean abort);
    ///   * the data-loss canary holds: every name present pre-abort still
    ///     enumerates (the LEFT leaf was restored, not left half-rewritten).
    func testNoLeakAfterMidCommitLeafSplitFailure() async throws {
        let volume = try await freshFormattedVolume(sizeMiB: 256, label: "NOLEAKC")
        let dirRN = try await makeSubdirectory(volume: volume, named: "splitfail")

        // Drive partway so the directory is multi-INDX-block (so a subsequent
        // insert will eventually hit a full leaf and split).
        let created = try await driveDirectory(
            volume: volume,
            dirRN: dirRN,
            entryCount: 800,
            namePrefix: "sf",
            bytesPerFile: 4096
        )
        XCTAssertGreaterThan(created, 300, "directory must be locality-grown before the split; got \(created)")
        let extentsBefore = try await indexAllocationExtentCount(volume: volume, dirRN: dirRN)
        XCTAssertGreaterThan(
            extentsBefore, 0,
            "directory must have a non-resident $INDEX_ALLOCATION (a leaf to split)"
        )

        // Snapshot the reachable name set pre-abort (data-loss canary).
        let entriesPre = try await volume.enumerate(directory: dirRN)
        let namesPre = Set(
            entriesPre.filter { $0.fileName.namespace != .dos }.map { $0.fileName.name }
        )

        // Arm the mid-commit fault. It is single-shot, so the FIRST leaf split
        // fires it and throws; non-splitting inserts before then succeed.
        let injected = NTFSError.ioFailure(description: "splitLeaf fault: mid-commit after-left-leaf")
        await volume._setSplitLeafFaultHookAfterLeftLeaf { throw injected }

        var triggered = false
        var freeBeforeAborted: UInt64 = 0
        var attempts = 0
        for i in 0..<3000 {
            attempts += 1
            let name = String(format: "sf-SPLIT-%05d.bin", i)
            // Snapshot free clusters IMMEDIATELY before this create so the
            // canary brackets exactly the create that aborts. Non-splitting
            // inserts allocate no clusters; the split allocates `newExtent`.
            let bm = try await volume.bitmap()
            freeBeforeAborted = bm.freeClusterCount
            do {
                _ = try await volume.createFile(named: name, inDirectory: dirRN)
            } catch let e as NTFSError {
                if case NTFSError.ioFailure(let desc) = e, desc.contains("splitLeaf fault") {
                    triggered = true
                    break
                }
                throw e  // unexpected error — surface it
            }
        }
        await volume._setSplitLeafFaultHookAfterLeftLeaf(nil)

        guard triggered else {
            throw XCTSkip("""
                no leaf split was triggered in \(attempts) createFile attempts on this fixture — \
                the mid-commit failure window was not exercised.
                """)
        }

        // (1) LEAK canary: the split's provisional clusters must be freed, so
        //     the free-cluster count returns to its pre-abort value exactly.
        let bmAfter = try await volume.bitmap()
        let freeAfter = bmAfter.freeClusterCount
        print("""
            === AC-5 NO-LEAK-ON-MID-COMMIT-SPLIT-FAILURE ===
            entries before split:       \(created)
            $INDEX_ALLOCATION extents:  \(extentsBefore)
            createFile attempts:        \(attempts)
            free clusters before abort: \(freeBeforeAborted)
            free clusters after abort:  \(freeAfter)
            ================================================
            """)
        XCTAssertEqual(
            freeAfter, freeBeforeAborted,
            """
            free-cluster count must be restored after a mid-commit split failure — \
            any shortfall is a LEAKED provisional INDX cluster the rollback failed to free. \
            before=\(freeBeforeAborted), after=\(freeAfter), leaked=\(Int64(freeBeforeAborted) - Int64(freeAfter)).
            """
        )

        // (2) Whole-volume deep audit clean (0 free-but-referenced catches a
        //     restored extension still naming a freed cluster).
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(
            sweep.isClean,
            """
            deep audit must be clean after a mid-commit split failure; got \
            freeButReferenced=\(sweep.freeButReferencedClusters), \
            outOfRange=\(sweep.outOfRangeClusters), \
            doubleAllocated=\(sweep.doubleAllocatedClusters), \
            unreadable=\(sweep.unreadableRecords.count)
            """
        )
        XCTAssertEqual(sweep.freeButReferencedClusters, 0, "0 free-but-referenced after mid-commit split failure")
        XCTAssertEqual(sweep.doubleAllocatedClusters, 0, "0 double-allocated after mid-commit split failure")

        // (3) No orphans — the rollback kept i30Committed false, so createFile
        //     reclaimed the child's MFT slot (no IN_USE-but-unreachable record).
        let orphanSet = try await orphans(in: volume)
        XCTAssertTrue(
            orphanSet.isEmpty,
            "no orphans after a clean mid-commit split rollback; got \(orphanSet.sorted())"
        )

        // (4) Data-loss canary: every name present pre-abort still enumerates
        //     (the destructively-trimmed LEFT leaf was restored). The directory
        //     must also still enumerate without throwing.
        let entriesPost = try await volume.enumerate(directory: dirRN)
        let namesPost = Set(
            entriesPost.filter { $0.fileName.namespace != .dos }.map { $0.fileName.name }
        )
        let missing = namesPre.subtracting(namesPost)
        XCTAssertTrue(
            missing.isEmpty,
            """
            post-abort: all pre-abort entries must still enumerate (the LEFT leaf must be \
            restored, not left half-rewritten); missing \(missing.sorted().prefix(5)).
            """
        )

        // (5) The directory is fully usable again: a fresh create after the
        //     rolled-back split succeeds and is reachable.
        let recoveryName = "sf-RECOVERY.bin"
        _ = try await volume.createFile(named: recoveryName, inDirectory: dirRN)
        let entriesRecovered = try await volume.enumerate(directory: dirRN)
        XCTAssertTrue(
            entriesRecovered.contains { $0.fileName.name == recoveryName },
            "a create after the rolled-back split must succeed and enumerate"
        )
    }
}
