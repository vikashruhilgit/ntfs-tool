import XCTest
@testable import NTFSCore

/// Regression coverage for **`$MFT` auto-grow** (fix/mft-autogrow).
///
/// Background — the weak-oracle trap this closes:
/// A real Windows quick-format starts `$MFT.$DATA` at just **16 records**
/// (the base system files) and grows it on demand as files are added. Our
/// own `mkntfs` over-allocates a ≥16 MiB / 16,384-record `$MFT`, so every
/// prior test (and the 22,419-file hardware copy) ran with a giant MFT and
/// **never exercised growth**. On a genuinely Windows-formatted drive the
/// very first user-file create needs MFT record 16 — past the initial
/// allocation — and pre-fix `allocateMFTRecord` threw
/// `"auto-grow is disabled"`, so `ntfsctl` could not write to the drive at
/// all.
///
/// These tests build a fixture that mirrors the real drive — a tight
/// **4-cluster / 16-record `$MFT`** via the test-only
/// `mftInitialClustersOverride` — and prove:
///   1. createFile now grows `$MFT` and succeeds past slot 16;
///   2. sustained creation through MANY growth rounds AND directory
///      leaf-splits / height-grows stays structurally clean (whole-volume
///      deep audit + orphan walk) — the "grow + leaf-split interaction" the
///      old code comment flagged as a corruption hazard;
///   3. files read back byte-exact after growth + reopen-from-disk.
final class MFTAutoGrowTests: XCTestCase {

    /// Format a fresh writable image whose `$MFT.$DATA` covers exactly
    /// `mftRecords` records (default 16 — the Windows quick-format shape),
    /// then open it. Returns the Volume and the backing file path (for
    /// reopen-from-disk). Auto-cleans the tmp file.
    private func tightMFTVolume(
        sizeMiB: Int = 128, mftRecords: UInt64 = 16, label: String = "MFTGROW"
    ) async throws -> (volume: Volume, path: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mft-autogrow-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await device.size()
        // 1024-byte records, 4096-byte clusters → 4 records/cluster.
        let clusters = max(UInt64(4), (mftRecords + 3) / 4)
        try await Volume.formatNTFS(
            device: device,
            deviceSizeBytes: size,
            label: label,
            volumeSerial: 0x0123_4567_89AB_CDEF,
            mftInitialClustersOverride: clusters
        )
        return (try await Volume(device: device), path)
    }

    /// $MFT.$DATA allocatedSize in records (the materialized capacity).
    private func mftAllocatedRecords(_ volume: Volume) async throws -> UInt64 {
        let r0 = try await volume.mft().record(at: 0)
        let attrs = try r0.attributes()
        guard let data = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else { return 0 }
        switch data.value {
        case let .resident(b, _):                     return UInt64(b.count) / 1024
        case let .nonResident(_, _, _, _, a, _, _, _): return a / 1024
        }
    }

    /// IN_USE base records (rn >= 16, not an extension) that are NOT reachable
    /// from the root by an $I30 walk — the orphan set.
    private func orphans(in volume: Volume, maxRN: UInt64) async throws -> Set<UInt64> {
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

    // MARK: - 1. The exact pre-fix failure: first user file needs slot 16.

    /// Pre-fix this threw `unsupportedFeature("...auto-grow is disabled...")`
    /// on the FIRST create. Post-fix it grows $MFT and succeeds.
    func testFirstCreateGrowsMFTPastInitialSixteenRecords() async throws {
        let (volume, _) = try await tightMFTVolume(mftRecords: 16)
        let before = try await mftAllocatedRecords(volume)
        XCTAssertEqual(before, 16, "fixture should start with a 16-record $MFT (Windows shape)")

        let rn = try await volume.createFile(named: "first.txt", inDirectory: 5)
        XCTAssertGreaterThanOrEqual(rn, 16, "first user record must be >= 16")

        let after = try await mftAllocatedRecords(volume)
        XCTAssertGreaterThan(after, before, "$MFT.$DATA must have grown to back the new record")

        let names = try await volume.enumerate(directory: 5).map { $0.name }
        XCTAssertTrue(names.contains("first.txt"), "created file should be in root index")
    }

    // MARK: - 2. Sustained growth × leaf-split, deep-audit clean.

    /// Create a few thousand files across several subdirectories on a
    /// tight-MFT volume. Forces dozens of $MFT growth rounds (16 → thousands
    /// of records) AND directory $I30 going LARGE_INDEX with leaf splits /
    /// height grows, concurrently. Then assert the whole-volume deep audit is
    /// clean and there are no orphans — the grow + leaf-split interaction
    /// produces no aliased / leaked / dangling state.
    func testSustainedCreateThroughGrowthAndLeafSplitsVerifiesDeepClean() async throws {
        let (volume, _) = try await tightMFTVolume(sizeMiB: 256, mftRecords: 16)
        let startAlloc = try await mftAllocatedRecords(volume)

        let dirCount = 4
        var dirs: [UInt64] = []
        for d in 0..<dirCount {
            dirs.append(try await volume.createFile(named: "dir\(d)", inDirectory: 5, isDirectory: true))
        }

        let perDir = 800            // 4 × 800 = 3200 files → far past a 16-record MFT
        for (d, dirRN) in dirs.enumerated() {
            for i in 0..<perDir {
                _ = try await volume.createFile(named: String(format: "f-%d-%05d.bin", d, i), inDirectory: dirRN)
            }
        }

        let endAlloc = try await mftAllocatedRecords(volume)
        XCTAssertGreaterThan(endAlloc, startAlloc + 100,
            "MFT should have grown by hundreds of records (was \(startAlloc), now \(endAlloc))")

        // Every file enumerable in its directory (nothing dropped during a
        // growth-triggering insert).
        for (d, dirRN) in dirs.enumerated() {
            let names = try await volume.enumerate(directory: dirRN)
                .filter { $0.fileName.namespace != .dos }.map { $0.name }
            XCTAssertEqual(Set(names).count, perDir, "dir\(d) lost entries across growth/leaf-split")
        }

        // Headline: whole-volume deep audit spotless.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(sweep.isClean, """
            deep audit must be clean after grow×leaf-split; got \
            freeButReferenced=\(sweep.freeButReferencedClusters), \
            outOfRange=\(sweep.outOfRangeClusters), \
            doubleAllocated=\(sweep.doubleAllocatedClusters), \
            unreadable=\(sweep.unreadableRecords.count)
            """)

        // And no orphans across the (now several-thousand-record) MFT.
        let orphanSet = try await orphans(in: volume, maxRN: endAlloc)
        XCTAssertTrue(orphanSet.isEmpty, "no orphans after grow×leaf-split; got \(orphanSet.sorted())")
    }

    // MARK: - 3. Bytes survive growth + reopen-from-disk.

    func testFileContentSurvivesMFTGrowthAndReopen() async throws {
        let (volume, path) = try await tightMFTVolume(mftRecords: 16)

        // Create enough files to force growth, capture one created AFTER growth.
        var target: UInt64 = 0
        let payload = Data((0..<5000).map { UInt8(($0 &* 7 &+ 13) & 0xFF) })
        for i in 0..<300 {
            let rn = try await volume.createFile(named: String(format: "g-%05d.dat", i), inDirectory: 5)
            if i == 250 { target = rn }
        }
        let grownTo = try await mftAllocatedRecords(volume)
        XCTAssertGreaterThan(grownTo, 16, "growth should have occurred")

        var sent = false
        try await volume.writeFile(at: target, totalSize: UInt64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }

        // Reopen read-only from a fresh handle (no flock conflict with the
        // still-open writer) — proves the grown $MFT + new record are durable
        // on disk, not just cached.
        let v2 = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let readBack = try await v2.readFile(at: target)
        XCTAssertEqual(readBack, payload, "content must survive MFT growth + reopen")
    }

    // MARK: - 4. Mid-transaction growth: headroom reserved at transaction entry

    /// Consume every free, already-materialized `$MFT` slot, leaving the MFT
    /// with zero usable headroom without growing it.
    ///
    /// NOTE: this marks `$MFT.$BITMAP` bits without writing records behind
    /// them — an artificial state, but exactly the *allocator* state that
    /// occurs naturally the instant before a growth boundary is crossed,
    /// which is what this test needs to pin down deterministically.
    private func exhaustMaterializedMFTSlots(_ volume: Volume) async throws -> Int {
        var taken = 0
        while (try? await volume.allocateMFTRecord(allowGrowth: false)) != nil {
            taken += 1
            if taken > 100_000 { break }
        }
        return taken
    }

    /// The hardware abort: `$MFT` growth is disabled at the two migration
    /// allocation sites, so when a migration — rather than `createFile` — is
    /// the caller that crosses a 256-record growth boundary, the whole copy
    /// dies with:
    ///
    ///   "MFT slot N is free in $MFT.$BITMAP but past $MFT.$DATA's
    ///    allocatedSize; allocateMFTRecord(allowGrowth:false) —
    ///    mid-transaction growth is disabled"
    ///
    /// Seen on an 11,500-file copy that aborted at file 8,180, while an
    /// earlier identical run crossed ~62 boundaries without colliding. The fix
    /// reserves headroom at transaction entry, where growing is safe.
    func testMigrationDoesNotAbortWhenMFTIsAtItsGrowthBoundary() async throws {
        let (volume, _) = try await tightMFTVolume(sizeMiB: 32, mftRecords: 64)

        // Put the MFT exactly at its growth boundary: no materialized slot
        // left, so the NEXT allocation must grow.
        let consumed = try await exhaustMaterializedMFTSlots(volume)
        XCTAssertGreaterThan(consumed, 0, "expected to consume at least one free MFT slot")

        // (a) The failure mode itself, at its true site. This is what the two
        //     migration callsites do, and what killed the hardware copy: a
        //     mid-transaction allocation that is not permitted to grow.
        //     Two shapes of the same condition, depending on whether
        //     $MFT.$BITMAP happens to track bits beyond $MFT.$DATA's
        //     allocatedSize: `unsupportedFeature("...mid-transaction growth
        //     is disabled")` when a free bit exists past $DATA (the shape the
        //     hardware hit), `outOfSpace` when the tracked range is exactly
        //     full. Either way the allocation cannot proceed without growing.
        do {
            _ = try await volume.allocateMFTRecord(allowGrowth: false)
            XCTFail("expected mid-transaction allocation to fail with no materialized headroom")
        } catch let error as NTFSError {
            switch error {
            case let .unsupportedFeature(description):
                XCTAssertTrue(
                    description.contains("mid-transaction growth is disabled"),
                    "expected the hardware abort message; got: \(description)"
                )
            case .outOfSpace:
                break
            default:
                XCTFail("expected unsupportedFeature or outOfSpace, got \(error)")
            }
        }

        // (b) Reserving headroom at transaction entry — where growing IS
        //     safe — makes the same allocation succeed.
        let allocatedBefore = try await mftAllocatedRecords(volume)
        try await volume.ensureMFTHeadroom()
        let allocatedAfter = try await mftAllocatedRecords(volume)
        XCTAssertGreaterThan(
            allocatedAfter, allocatedBefore,
            "ensureMFTHeadroom must grow $MFT when no materialized slot is free"
        )

        let slot = try await volume.allocateMFTRecord(allowGrowth: false)
        XCTAssertGreaterThanOrEqual(
            slot, MFT.firstUserRecord,
            "post-headroom mid-transaction allocation must succeed"
        )
    }

    /// End-to-end: with the MFT sitting exactly at its growth boundary, a
    /// `writeFile` must reserve headroom at entry rather than carrying the
    /// risk into its transaction — and must still write correct bytes.
    func testWriteFileReservesHeadroomAtTransactionEntry() async throws {
        let (volume, _) = try await tightMFTVolume(sizeMiB: 32, mftRecords: 64)
        let victim = try await volume.createFile(named: "boundary.bin", inDirectory: 5)
        _ = try await exhaustMaterializedMFTSlots(volume)
        let allocatedBefore = try await mftAllocatedRecords(volume)

        let total = 300 * 1024
        var payload = Data(count: total)
        for i in 0..<total { payload[i] = UInt8((i &* 23 &+ 5) & 0xFF) }
        var cursor = 0
        try await volume.writeFile(at: victim, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            defer { cursor += take }
            return payload.subdata(in: cursor..<(cursor + take))
        }

        let allocatedAfter = try await mftAllocatedRecords(volume)
        XCTAssertGreaterThan(
            allocatedAfter, allocatedBefore,
            "writeFile should have grown $MFT at entry, leaving headroom for a mid-write migration"
        )
        let readBack = try await volume.readFile(at: victim)
        XCTAssertEqual(readBack, payload, "content must survive a growth-boundary write")
    }

    /// The invariant behind the fix: after `createFile` returns, a subsequent
    /// mid-transaction allocation always finds a materialized free slot.
    func testCreateFileLeavesMaterializedMFTHeadroom() async throws {
        let (volume, _) = try await tightMFTVolume(sizeMiB: 32, mftRecords: 16)

        // Walk well past several 256-record growth boundaries.
        for i in 0..<40 {
            _ = try await volume.createFile(named: "f\(i).bin", inDirectory: 5)

            let allocated = try await mftAllocatedRecords(volume)
            let bm = try await volume.mftBitmap()
            var free = 0
            var n = MFT.firstUserRecord
            while n < min(bm.clusterCount, allocated) {
                if !bm.isAllocated(cluster: n) { free += 1 }
                n += 1
            }
            XCTAssertGreaterThanOrEqual(
                free, 1,
                "after createFile #\(i) there must be materialized headroom for a migration to allocate into"
            )
        }
    }
}
