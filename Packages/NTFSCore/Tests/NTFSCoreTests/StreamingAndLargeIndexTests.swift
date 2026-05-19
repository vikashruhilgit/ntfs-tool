import XCTest
@testable import NTFSCore

/// Tests covering the post-v0.1 capability gaps:
///  - Streaming `writeFile` (no 1 GiB cap, chunked memory profile).
///  - Bulk insert into LARGE_INDEX directories ($I30 B-tree descent).
///  - `Volume.resolvePath` path → MFT-recnum helper.
final class StreamingAndLargeIndexTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/'")
        }
        return sub.recordNumber
    }

    // MARK: - Streaming writeFile

    func testStreamingWriteFileRoundTripsLargePayload() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "stream.bin", inDirectory: parentRN)

        // Build a 256 KiB payload of deterministic bytes (cluster size 4096 → 64 clusters).
        let size = 256 * 1024
        var expected = Data(count: size)
        for i in 0..<size {
            expected[i] = UInt8((i * 31) & 0xFF)
        }
        // Feed in 7000-byte chunks so the chunk boundaries don't line up with
        // cluster boundaries — exercises the cross-extent slicing.
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(size)) {
            if cursor >= size { return Data() }
            let take = min(7000, size - cursor)
            let chunk = expected.subdata(in: cursor..<(cursor + take))
            cursor += take
            return chunk
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack.count, size, "read-back length mismatch")
        XCTAssertEqual(readBack, expected, "read-back bytes diverge from written")
    }

    func testStreamingWriteFileSmallStaysResident() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "tiny.txt", inDirectory: parentRN)

        // Below residentDataThreshold (~700 bytes) — gathers in memory and
        // writes resident $DATA.
        let payload = Data("streaming-but-small\n".utf8)
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(payload.count)) {
            if cursor >= payload.count { return Data() }
            let chunk = payload.subdata(in: cursor..<payload.count)
            cursor = payload.count
            return chunk
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack, payload)
    }

    func testStreamingWriteFileFromHostFile() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "from-host.bin", inDirectory: parentRN)

        // Drop a 64 KiB host file, write it via the file-path convenience.
        let hostPath = FileManager.default.temporaryDirectory.appendingPathComponent("ntfs-stream-test-\(UUID().uuidString).bin")
        var hostBytes = Data(count: 64 * 1024)
        for i in 0..<hostBytes.count { hostBytes[i] = UInt8((i * 7) & 0xFF) }
        try hostBytes.write(to: hostPath)
        addTeardownBlock { try? FileManager.default.removeItem(at: hostPath) }

        try await volume.writeFile(at: rn, fromFileAt: hostPath, chunkSize: 4096)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack, hostBytes)
    }

    func testStreamingReadFileSliceFollowsWrite() async throws {
        // readFileSlice has no 1 GiB cap; verify it round-trips chunked
        // streaming reads of the written content.
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "sliced.bin", inDirectory: parentRN)

        let size = 32 * 1024
        var expected = Data(count: size)
        for i in 0..<size { expected[i] = UInt8(i & 0xFF) }
        try await volume.write(at: rn, offset: 0, bytes: expected)

        // Stream-read in 1 KiB slices.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        var assembled = Data()
        var offset: UInt64 = 0
        while assembled.count < size {
            let chunk = try await reopened.readFileSlice(at: rn, offset: offset, length: 1024)
            if chunk.isEmpty { break }
            assembled.append(chunk)
            offset += UInt64(chunk.count)
        }
        XCTAssertEqual(assembled, expected, "streaming readFileSlice should reassemble the full file")
    }

    // MARK: - LARGE_INDEX bulk insert

    func testBulkInsertIntoLargeIndexRoot() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // The fixture root is LARGE_INDEX (15 entries — too many for resident
        // $INDEX_ROOT). Insert N new files; each should land in some leaf INDX
        // block via B-tree descent. N=20 fits comfortably below the
        // single-leaf-full ceiling on this fixture's 4 KiB INDX block; the
        // explicit leaf-full assertion lives in its own test below.
        var createdRecnums: [UInt64] = []
        var createdNames: [String] = []
        for i in 0..<20 {
            let name = String(format: "bulk-%04d.txt", i)
            let rn = try await volume.createFile(named: name, inDirectory: 5)
            createdRecnums.append(rn)
            createdNames.append(name)
        }
        XCTAssertEqual(Set(createdRecnums).count, 20, "each insert should get a distinct MFT slot")

        // Re-open and enumerate — every inserted name should appear exactly once.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })
        for name in createdNames {
            XCTAssertTrue(names.contains(name), "inserted '\(name)' missing from re-read enumeration")
        }
    }

    /// Reproduces the leaf-split orphan bug observed against the user's
    /// real 4 TB WD drive: a `cp -r`-style sequence (createFile +
    /// writeFile, the writeFile triggering refreshParentI30Size + mtime
    /// bump) into a LARGE_INDEX directory eventually loses some entries
    /// silently. The split self-check should fire at the moment of
    /// corruption.
    func testLeafSplitOrphansBugUnderCpRWorkload() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Pre-grow $MFT.$DATA so we have enough slots to trigger multiple
        // leaf splits — the small fixture caps at ~60 records by default,
        // not enough to reach the second split. The growth path itself is
        // tested elsewhere; here we just need the slots.
        try await volume.growMFTDataByClusters(8)   // +32 records
        try await volume.growMFTDataByClusters(8)   // +32 more

        var inserted: [(name: String, rn: UInt64)] = []
        let payload = Data("test content for split-orphan repro\n".utf8)
        var firstLoss: (iter: Int, lostNames: [String])?
        for i in 0..<200 {
            let name = String(format: "cp-repro-%04d.txt", i)
            do {
                let rn = try await volume.createFile(named: name, inDirectory: 5)
                try await volume.write(at: rn, offset: 0, bytes: payload)
                inserted.append((name, rn))
            } catch NTFSError.unsupportedFeature {
                break
            }
            // After EVERY iter: reopen fresh from disk + check every
            // previously-inserted name. Capture the iter where loss
            // first occurs, but keep going so we know the total damage.
            // Per-iter LIVE check via active volume (no fd switching).
            if firstLoss == nil {
                let liveNamesNow = Set(try await volume.enumerate(directory: 5).map { $0.name })
                let lost = inserted.map(\.name).filter { !liveNamesNow.contains($0) }
                if !lost.isEmpty {
                    firstLoss = (iter: i, lostNames: lost)
                    FileHandle.standardError.write(Data(
                        "[FIRST LOSS] iter=\(i) just-inserted=\(name) total-inserted=\(inserted.count) lost-count=\(lost.count) lost=\(lost.sorted())\n".utf8
                    ))
                }
            }
        }
        // First check via the SAME (still-open) volume — should see all.
        let liveNames = Set(try await volume.enumerate(directory: 5).map { $0.name })
        let liveMissing = inserted.map(\.name).filter { !liveNames.contains($0) }
        FileHandle.standardError.write(Data("[end-of-loop] inserted=\(inserted.count) live_visible=\(liveNames.filter { $0.hasPrefix("cp-repro") }.count) live_missing=\(liveMissing.count)\n".utf8))

        // Dump $INDEX_ALLOCATION state: how many leaves, what each contains.
        let mft = await volume.mft()
        let parent = try await mft.record(at: 5)
        let parentAttrs = try parent.attributes()
        if let allocAttr = parentAttrs.first(where: { $0.type == .indexAllocation && $0.nameOrEmpty == "$I30" }),
           case let .nonResident(_, _, _, _, _, _, _, extents) = allocAttr.value {
            FileHandle.standardError.write(Data("[$INDEX_ALLOCATION] extents=\(extents.map { "(LCN=\($0.startLCN ?? 0), clusters=\($0.clusterCount))" })\n".utf8))
            // Walk each LEAF independently and report its first/last names.
            let clusterBytes = UInt64(volume.bytesPerCluster)
            let blockSize = Int(volume.indexRecordSizeBytes)
            let sectorSize = Int(volume.boot.bytesPerSector)
            var vcnCursor: UInt64 = 0
            for extent in extents {
                guard let startLCN = extent.startLCN else { continue }
                for c in 0..<extent.clusterCount {
                    let vcn = vcnCursor + c
                    let lcn = startLCN + c
                    let raw = try await volume.device.read(offset: lcn * clusterBytes, length: blockSize)
                    if let block = try? IndexAllocationBlock.parse(raw, sectorSize: sectorSize) {
                        let names = block.entries.compactMap { $0.fileName?.name }.filter { $0.hasPrefix("cp-repro") }.sorted()
                        FileHandle.standardError.write(Data("[leaf VCN=\(vcn) LCN=\(lcn)] entries=\(block.entries.count) cp-repro-count=\(names.count) first=\(names.first ?? "-") last=\(names.last ?? "-")\n".utf8))
                    } else {
                        FileHandle.standardError.write(Data("[leaf VCN=\(vcn) LCN=\(lcn)] PARSE FAILED\n".utf8))
                    }
                }
                vcnCursor += extent.clusterCount
            }
        }

        // Final reopen check: reopen the fixture from disk and verify
        // every inserted name is visible. The split-time verifier guards
        // each split's atomicity; this guards the END state.
        let finalReader = try FileHandleBlockDevice(openingFileAt: path)
        let finalReopen = try await Volume(device: finalReader)
        let finalNames = Set(try await finalReopen.enumerate(directory: 5).map { $0.name })
        let stillMissing = inserted.map(\.name).filter { !finalNames.contains($0) }
        FileHandle.standardError.write(Data("[final-reopen] inserted=\(inserted.count) reopen_visible=\(finalNames.filter { $0.hasPrefix("cp-repro") }.count) reopen_missing=\(stillMissing.count)\n".utf8))
        // Known v0.2 bug: after the 4th leaf split (around insert 75),
        // entries from the 4th leaf's range silently vanish on disk.
        // Tracked in STATUS.md as v0.3 work; this test serves as the
        // regression target once the fix lands.
        XCTAssertTrue(
            stillMissing.isEmpty,
            "Known v0.2 leaf-split silent-orphan bug: \(stillMissing.count) entries missing on disk after \(inserted.count) cp-style inserts. Missing: \(stillMissing.prefix(5).joined(separator: ", "))\(stillMissing.count > 5 ? "..." : "")"
        )

        // v0.3 orphan-detection assertion: mirror `ntfsctl verify`'s full
        // reachability walk from root. Any user MFT record with IN_USE=1
        // that isn't reachable from root → orphan → createFile failed to
        // clean up after a downstream throw.
        let finalMFT = await finalReopen.mft()
        var inUseUserRecords: Set<UInt64> = []
        let maxRecNum: UInt64 = 256
        for rn in 0..<maxRecNum {
            guard let rec = try? await finalMFT.record(at: rn) else { continue }
            guard rec.isInUse else { continue }
            if rn >= 16 { inUseUserRecords.insert(rn) }
        }
        var reachable: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dirRN = queue.popLast() {
            guard let entries = try? await finalReopen.enumerate(directory: dirRN) else { continue }
            for e in entries where e.fileName.namespace != .dos {
                if !reachable.contains(e.recordNumber) {
                    reachable.insert(e.recordNumber)
                    if e.isDirectory {
                        queue.append(e.recordNumber)
                    }
                }
            }
        }
        let reachableUser = reachable.filter { $0 >= 16 }
        let orphans = inUseUserRecords.subtracting(reachableUser)
        FileHandle.standardError.write(Data(
            "[orphan-check] in_use_user=\(inUseUserRecords.count) reachable_user=\(reachableUser.count) inserted=\(inserted.count) orphans=\(orphans.count) orphan_recnums=\(orphans.sorted().prefix(20))\n".utf8
        ))
        XCTAssertTrue(
            orphans.isEmpty,
            "createFile orphan-rollback bug: \(orphans.count) MFT slots IN_USE=1 but unreachable. Recnums: \(orphans.sorted().prefix(10))"
        )
    }

    /// v0.4 Phase 1: bulk-insert mode skips per-file refreshParentI30Size.
    /// Wrap a batch of file inserts in beginBulkInsert / endBulkInsert and
    /// confirm every write that would have triggered a size-hint refresh
    /// is counted as skipped. This is the perf foundation for cp -r: the
    /// 22k-file phone-backup workload was paying one INDX-block rewrite per
    /// file write just to update Windows Explorer's "Size" column.
    func testBulkInsertSkipsSizeHintRefresh() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        try await volume.growMFTDataByClusters(8)

        // Before bulk insert: skip-count starts at zero.
        let initialSkipped = await volume.bulkInsertSkippedRefreshCount()
        XCTAssertEqual(initialSkipped, 0)

        // Open bulk-insert window targeting root (recnum 5). The same parent
        // recnum cp -r uses when copying into the root of a fresh dir.
        try await volume.beginBulkInsert(into: 5)

        // Insert + write 25 files. Each write would normally trigger one
        // refreshParentI30Size; with bulk insert active each becomes a
        // no-op + counter bump.
        let payload = Data("phase1 bulk insert\n".utf8)
        for i in 0..<25 {
            let name = String(format: "bulk-%04d.txt", i)
            let rn = try await volume.createFile(named: name, inDirectory: 5)
            try await volume.write(at: rn, offset: 0, bytes: payload)
        }

        let skipped = try await volume.endBulkInsert()
        XCTAssertEqual(
            skipped, 25,
            "Expected 25 skipped size-hint refreshes during bulk insert (one per write); got \(skipped)"
        )

        // After endBulkInsert, the counter resets and subsequent writes
        // resume their normal (refreshing) behavior.
        let postSkipped = await volume.bulkInsertSkippedRefreshCount()
        XCTAssertEqual(postSkipped, 0)
        let rn = try await volume.createFile(named: "post-bulk.txt", inDirectory: 5)
        try await volume.write(at: rn, offset: 0, bytes: payload)
        let postSkipped2 = await volume.bulkInsertSkippedRefreshCount()
        XCTAssertEqual(
            postSkipped2, 0,
            "After endBulkInsert, subsequent writes should NOT increment the skip counter"
        )

        // Sanity: nested bulk insert is rejected.
        try await volume.beginBulkInsert(into: 5)
        do {
            try await volume.beginBulkInsert(into: 5)
            XCTFail("Expected nested beginBulkInsert to throw")
        } catch NTFSError.unsupportedFeature {
            // expected
        }
        _ = try await volume.endBulkInsert()

        // All 25 inserted files must still be reachable + readable — the
        // optimization is purely about deferring cosmetic size hints, not
        // skipping any actual content writes.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let names = Set(try await reopen.enumerate(directory: 5).map { $0.name })
        for i in 0..<25 {
            let n = String(format: "bulk-%04d.txt", i)
            XCTAssertTrue(names.contains(n), "bulk-inserted file \(n) missing from reopen")
        }
    }

    /// v0.3 hardware-shape repro: mimic `cp -r` of a deeply-nested source
    /// tree (a parent dir + many child files all under it, plus a sibling
    /// dir + a deeper subdir). The user's 22,419-file phone backup workload
    /// failed with 11 orphans on real hardware; this test exercises the same
    /// shape — directory creates interleaved with file inserts that span
    /// multiple leaf splits — and asserts the orphan rollback holds.
    func testCpRecursiveNestedDirsOrphanFreeUnderPressure() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        try await volume.growMFTDataByClusters(8)
        try await volume.growMFTDataByClusters(8)

        // Step 1: create a destination "gallery" dir at root.
        let galleryRN = try await volume.createFile(named: "gallery", inDirectory: 5, isDirectory: true)
        // Step 2: under gallery, create a subdir "backup" that we will then
        //         fill with many files (mirrors cp -r's "fill one dir until
        //         it splits" pattern).
        let backupRN = try await volume.createFile(named: "backup", inDirectory: galleryRN, isDirectory: true)

        // Step 3: pour files into backup/ until something fails.
        var insertedFiles: [String] = []
        let payload = Data("hi\n".utf8)
        for i in 0..<300 {
            let name = String(format: "file-%04d.dat", i)
            do {
                let rn = try await volume.createFile(named: name, inDirectory: backupRN)
                try await volume.write(at: rn, offset: 0, bytes: payload)
                insertedFiles.append(name)
            } catch NTFSError.unsupportedFeature {
                break
            }
        }

        // Step 4: reopen + walk reachability vs IN_USE, exactly like
        //         `ntfsctl verify` does.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopen = try await Volume(device: reader)
        let mft = await reopen.mft()

        var inUseUser: Set<UInt64> = []
        for rn: UInt64 in 0..<256 {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.isInUse, rn >= 16 { inUseUser.insert(rn) }
        }

        var reachable: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dir = queue.popLast() {
            guard let entries = try? await reopen.enumerate(directory: dir) else { continue }
            for e in entries where e.fileName.namespace != .dos {
                if !reachable.contains(e.recordNumber) {
                    reachable.insert(e.recordNumber)
                    if e.isDirectory { queue.append(e.recordNumber) }
                }
            }
        }
        let reachableUser = reachable.filter { $0 >= 16 }
        let orphans = inUseUser.subtracting(reachableUser)
        FileHandle.standardError.write(Data(
            "[nested-cp] inserted_files=\(insertedFiles.count) in_use_user=\(inUseUser.count) reachable_user=\(reachableUser.count) orphans=\(orphans.count) orphan_recnums=\(orphans.sorted().prefix(20))\n".utf8
        ))
        XCTAssertTrue(
            orphans.isEmpty,
            "Nested cp -r orphan-rollback: \(orphans.count) orphans after \(insertedFiles.count) successful file inserts into a 2-deep subdir. Recnums: \(orphans.sorted().prefix(10))"
        )
    }

    /// T1.2: leaf split now works. Insert enough entries to overflow the
    /// initial leaf (~50 with typical filenames), confirm split fires and
    /// all entries remain reachable in the directory enumeration. The cap
    /// now comes from $MFT growth (separate feature), not leaf split.
    func testLargeIndexLeafSplitWorks() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        var inserted: [String] = []
        for i in 0..<200 {
            let name = String(format: "leaf-split-%04d.txt", i)
            do {
                _ = try await volume.createFile(named: name, inDirectory: 5)
                inserted.append(name)
            } catch NTFSError.unsupportedFeature(let desc) where
                desc.contains("auto-grow is disabled") ||
                desc.contains("would overflow parent record") {
                // Stop at the next ceiling — either $MFT auto-grow not
                // wired (v0.2 limitation; growMFTDataByClusters exists
                // but isn't auto-invoked), or $INDEX_ROOT grew too many
                // interior entries to fit in the parent MFT record
                // (tree-height growth, separate future feature). Either
                // is fine — as long as leaf split itself worked.
                break
            }
        }
        XCTAssertGreaterThan(inserted.count, 40, "leaf split should accept far more than the ~30-entry single-leaf cap; got \(inserted.count)")

        // Re-open and verify every inserted name is reachable.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let names = Set(try await reopened.enumerate(directory: 5).map { $0.name })
        for n in inserted {
            XCTAssertTrue(names.contains(n), "inserted '\(n)' missing from enumeration after leaf splits")
        }
    }

    func testLargeIndexInsertSurvivesDeleteRoundTrip() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        var rns: [UInt64] = []
        for i in 0..<10 {
            let name = "rt-\(i).bin"
            let rn = try await volume.createFile(named: name, inDirectory: 5)
            rns.append(rn)
        }
        for rn in rns {
            try await volume.deleteFile(at: rn)
        }

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })
        for i in 0..<10 {
            XCTAssertFalse(names.contains("rt-\(i).bin"), "deleted entry rt-\(i).bin still present in enumeration")
        }
    }

    // MARK: - Path resolution

    func testResolvePathRoot() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let rootRN1 = try await volume.resolvePath("/")
        let rootRN2 = try await volume.resolvePath("")
        let rootRN3 = try await volume.resolvePath(".")
        XCTAssertEqual(rootRN1, 5)
        XCTAssertEqual(rootRN2, 5)
        XCTAssertEqual(rootRN3, 5)
    }

    func testResolvePathOneLevel() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // 'sub' is the always-resident subdir in the fixture.
        let resolved = try await volume.resolvePath("/sub")
        XCTAssertNotNil(resolved)
        let subRN = try await subDirRecordNumber(volume: volume)
        XCTAssertEqual(resolved, subRN)
    }

    func testResolvePathMissing() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let missing = try await volume.resolvePath("/no-such-thing-exists")
        XCTAssertNil(missing)
    }

    // MARK: - mtime + size hint refresh (T1.3 + T1.4)

    func testWriteBumpsStandardInformationMTime() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "mtime.txt", inDirectory: parentRN)

        // Read the created mtime, then write content, then re-read mtime.
        let mft = await volume.mft()
        func mtimeOf(_ recordNumber: UInt64) async throws -> Date? {
            let rec = try await mft.record(at: recordNumber)
            let attrs = try rec.attributes()
            guard let si = attrs.first(where: { $0.type == .standardInformation }),
                  case let .resident(b, _) = si.value else { return nil }
            return try StandardInformation.parse(b).modificationTime
        }
        let mtimeAtCreate = try await mtimeOf(rn)
        // Sleep a hair to ensure clock advances (FILETIME 100ns resolution).
        try await Task.sleep(nanoseconds: 50_000_000)
        try await volume.write(at: rn, offset: 0, bytes: Data("payload".utf8))

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let mftReopened = await reopened.mft()
        let postRec = try await mftReopened.record(at: rn)
        let postSI = try StandardInformation.parse(
            (try postRec.attributes().first(where: { $0.type == .standardInformation }))!.value.residentBytes!
        )
        guard let postMTime = postSI.modificationTime, let preMTime = mtimeAtCreate else {
            return XCTFail("mtime missing")
        }
        XCTAssertGreaterThan(postMTime, preMTime, "write must bump $STANDARD_INFORMATION mtime")
    }

    func testWriteRefreshesSizeHintInLargeIndexParent() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        // Root (recnum 5) is LARGE_INDEX on this fixture — perfect for the test.
        let rn = try await volume.createFile(named: "sized.bin", inDirectory: 5)
        let payload = Data(repeating: 0xAA, count: 8192)
        try await volume.write(at: rn, offset: 0, bytes: payload)

        // Re-open, enumerate root, find sized.bin, check its $FILE_NAME realSize.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let entries = try await reopened.enumerate(directory: 5)
        guard let entry = entries.first(where: { $0.name == "sized.bin" }) else {
            return XCTFail("sized.bin missing from enumeration")
        }
        XCTAssertEqual(entry.fileName.realSize, UInt64(payload.count),
                       "$I30 entry's $FILE_NAME.realSize must reflect post-write size in LARGE_INDEX parent")
    }

    // MARK: - MFT $BITMAP allocator (T1.1)

    func testMFTBitmapReflectsAllocations() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        // Snapshot current bitmap state.
        let bmBefore = try await volume.mftBitmap()

        // Create a file — should allocate via bitmap.
        let rn = try await volume.createFile(named: "alloc-via-bitmap.txt", inDirectory: parentRN)

        // The just-allocated slot should be marked in the bitmap.
        let bmAfter = try await volume.mftBitmap()
        XCTAssertTrue(bmAfter.isAllocated(cluster: rn), "newly-allocated recnum \(rn) should be marked in $MFT.$BITMAP")
        XCTAssertFalse(bmBefore.isAllocated(cluster: rn), "the slot should have been free in the pre-allocation bitmap snapshot")

        // Re-open the volume — bitmap should persist.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let bmReopened = try await reopened.mftBitmap()
        XCTAssertTrue(bmReopened.isAllocated(cluster: rn), "bitmap allocation must hit disk")
    }

    func testMFTBitmapClearsOnDelete() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "to-delete.txt", inDirectory: parentRN)
        let preDelete = try await volume.mftBitmap()
        XCTAssertTrue(preDelete.isAllocated(cluster: rn))

        try await volume.deleteFile(at: rn)

        let bm = try await volume.mftBitmap()
        XCTAssertFalse(bm.isAllocated(cluster: rn), "delete should clear the $MFT.$BITMAP bit")
    }

    func testMFTBitmapSurvivesManyAllocations() async throws {
        // Stress: allocate as many slots as the fixture's $MFT.$DATA holds
        // (~68 records on this fixture). Each allocation should consult the
        // bitmap, never re-use an in-use slot.
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        var assigned: Set<UInt64> = []
        var hitMFTGrowthGuard = false
        for i in 0..<60 {
            do {
                let rn = try await volume.createFile(named: "stress-\(i).txt", inDirectory: parentRN)
                XCTAssertFalse(assigned.contains(rn), "recnum \(rn) handed out twice")
                XCTAssertGreaterThanOrEqual(rn, 16, "must allocate in user region")
                assigned.insert(rn)
            } catch NTFSError.unsupportedFeature(let d) where d.contains("auto-grow is disabled") {
                // Hit the $MFT growth boundary — expected with our small fixture.
                hitMFTGrowthGuard = true
                break
            } catch NTFSError.unsupportedFeature(let d) where d.contains("leaf full") {
                // Hit LARGE_INDEX leaf-full — also expected before T1.2 lands.
                break
            }
        }
        // Either we allocated all 60 OR we hit the materialization guard
        // with a clear error. Either is acceptable; the bug we're testing
        // for is silent slot duplication.
        XCTAssertGreaterThan(assigned.count, 20, "should accept at least 20 bitmap-driven allocations")
        _ = hitMFTGrowthGuard  // not asserting either way; depends on fixture
    }

    // MARK: - Mid-file write

    func testMidFileOverwritePreservesSurroundingBytes() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "midwrite.bin", inDirectory: parentRN)
        // Build a 16 KiB file with a deterministic pattern.
        var original = Data(count: 16 * 1024)
        for i in 0..<original.count { original[i] = UInt8(i & 0xFF) }
        try await volume.write(at: rn, offset: 0, bytes: original)

        // Overwrite a 100-byte chunk starting at offset 4097 (NOT cluster-aligned).
        let patch = Data(repeating: 0xAB, count: 100)
        try await volume.write(at: rn, offset: 4097, bytes: patch)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack.count, original.count, "file size should be unchanged by mid-file overwrite")
        // Bytes before 4097 unchanged
        XCTAssertEqual(readBack.prefix(4097), original.prefix(4097))
        // Bytes 4097..4197 are 0xAB
        XCTAssertEqual(readBack.subdata(in: 4097..<4197), patch)
        // Bytes 4197 onwards unchanged
        XCTAssertEqual(readBack.subdata(in: 4197..<readBack.count), original.subdata(in: 4197..<original.count))
    }

    // MARK: - Byte-precise truncate

    func testBytePreciseTruncateShrinksRealSize() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "trunc.bin", inDirectory: parentRN)
        var bytes = Data(count: 12 * 1024)
        for i in 0..<bytes.count { bytes[i] = UInt8((i * 13) & 0xFF) }
        try await volume.write(at: rn, offset: 0, bytes: bytes)
        // Truncate to a non-cluster-aligned size.
        try await volume.truncate(at: rn, newSize: 7321)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let readBack = try await reopened.readFile(at: rn)
        XCTAssertEqual(readBack.count, 7321, "truncate should land at exact byte size")
        XCTAssertEqual(readBack, bytes.prefix(7321))
    }

    // MARK: - Rename

    func testRenameMovesEntryInSameDirectory() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let rn = try await volume.createFile(named: "old.txt", inDirectory: parentRN)

        try await volume.rename(at: rn, toName: "new.txt", inDirectory: nil)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let names = try await reopened.enumerate(directory: parentRN).map { $0.name }
        XCTAssertTrue(names.contains("new.txt"), "renamed entry should appear under new name")
        XCTAssertFalse(names.contains("old.txt"), "old name should be removed from parent")
    }

    func testRenameMovesEntryToDifferentDirectory() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let destDir = try await volume.createFile(named: "newdir", inDirectory: parentRN, isDirectory: true)
        let rn = try await volume.createFile(named: "movable.txt", inDirectory: parentRN)

        try await volume.rename(at: rn, toName: "movable.txt", inDirectory: destDir)

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let srcNames = try await reopened.enumerate(directory: parentRN).map { $0.name }
        let destNames = try await reopened.enumerate(directory: destDir).map { $0.name }
        XCTAssertFalse(srcNames.contains("movable.txt"), "removed from source")
        XCTAssertTrue(destNames.contains("movable.txt"), "appears in destination")
    }

    func testResolvePathTwoLevels() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // 'sub/nested.txt' is the always-present nested file in the fixture.
        let resolved = try await volume.resolvePath("/sub/nested.txt")
        XCTAssertNotNil(resolved, "should resolve nested fixture file")
    }
}
