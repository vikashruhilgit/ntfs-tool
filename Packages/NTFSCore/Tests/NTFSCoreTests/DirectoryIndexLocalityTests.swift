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
}
