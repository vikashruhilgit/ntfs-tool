import XCTest
@testable import NTFSCore

/// Tests for the runlist↔$Bitmap cross-check (`auditDataRunlistAgainstBitmap`
/// and `auditAllDataRunlistsAgainstBitmap`) that back `ntfsctl dump` and
/// `ntfsctl verify --deep`.
///
/// These are the v0.5 multi-extent / portability DIAGNOSTICS: a real WD-drive
/// fault where multi-extent `$DATA` files read byte-exact with our reader but
/// throw I/O errors in macOS's native NTFS driver. The audit classifies every
/// referenced cluster against `$Bitmap` as ALLOCATED / FREE(!) / OUT_OF_RANGE,
/// and the whole-volume sweep additionally detects cross-record double
/// allocation. The four scenarios below drive the REAL audit functions over a
/// real `Volume` on a writable `small.img` copy:
///
///   1. all-allocated (clean)        -> isClean
///   2. freed-but-referenced cluster -> freeButReferencedCount >= 1
///   3. out-of-range LCN             -> outOfRangeCount >= 1
///   4. double-allocation            -> doubleAllocatedClusters >= 1
///
/// Cases 1 and 2 use organically-created files; cases 3 and 4 byte-patch the
/// on-disk `$DATA` runlist of an organically-created file to manufacture an
/// LCN the allocator would never produce (out-of-range / aliasing another
/// file), because no mutating API can produce those states. The audit being
/// tested is PURE / read-only, so every check re-opens the image read-only.
final class RunlistBitmapAuditTests: XCTestCase {

    // MARK: - Fixture helpers

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Deterministic payload generator so writes are reproducible.
    private static func contentByte(at i: Int) -> UInt8 {
        UInt8((UInt64(i) &* 131 &+ 17) & 0xFF)
    }

    /// Create a file under `parentRN` and stream a non-resident multi-cluster
    /// payload into it via the REAL `writeFile` path. Returns its record number
    /// and the byte count written. The payload is sized to several clusters so
    /// the resulting `$DATA` is guaranteed non-resident (a real runlist to
    /// audit). Multi-extent is a bonus the audit doesn't require.
    private func createNonResidentFile(
        volume: Volume,
        named name: String,
        inDirectory parentRN: UInt64 = 5,
        clusters: UInt64 = 4
    ) async throws -> (recordNumber: UInt64, byteCount: Int) {
        let rn = try await volume.createFile(named: name, inDirectory: parentRN)
        // A few clusters, with a partial tail so realSize < allocatedSize.
        let total = Int(clusters * UInt64(volume.bytesPerCluster)) - 333
        var payload = Data(count: total)
        for i in 0..<total { payload[i] = Self.contentByte(at: i) }
        var cursor = 0
        try await volume.writeFile(at: rn, totalSize: UInt64(total)) {
            if cursor >= total { return Data() }
            let take = min(1 << 16, total - cursor)
            let chunk = payload.subdata(in: cursor..<(cursor + take))
            cursor += take
            return chunk
        }
        return (rn, total)
    }

    /// Re-open `path` read-only and return a fresh `Volume`. Mirrors how `dump`
    /// / `verify` open a device — proves the audit reads real on-disk state.
    private func reopenReadOnly(_ path: String) async throws -> Volume {
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        return try await Volume(device: reader)
    }

    /// Pull the first non-sparse extent's `startLCN` from a non-resident
    /// `$DATA` audit, or fail the test.
    private func firstAllocatedLCN(
        _ audit: RunlistBitmapAudit, file: StaticString = #filePath, line: UInt = #line
    ) throws -> UInt64 {
        guard let lcn = audit.extents.first(where: { !$0.isSparse })?.startLCN else {
            XCTFail("audit has no non-sparse extent to take an LCN from", file: file, line: line)
            throw XCTSkip("no allocated extent")
        }
        return lcn
    }

    // MARK: - On-disk $DATA runlist byte-patch (cases 3 & 4)

    /// Rewrite a record's unnamed non-resident `$DATA` runlist so its FIRST
    /// extent's startLCN becomes `newStartLCN`, leaving every other extent
    /// (count + relative position) intact and the runlist fully decodable.
    ///
    /// Rather than poke individual offset bytes (the first run's on-disk offset
    /// width on a tiny fixture is often only 1 byte, too narrow to hold an
    /// out-of-range LCN), this decodes the existing runlist with the project's
    /// real `DataRun.decode`, replaces extent[0]'s startLCN, then RE-ENCODES the
    /// whole runlist with the REAL encoder (`_encodeRunlistForTesting`) — which
    /// picks a wide-enough offset width automatically. The freshly-encoded
    /// runlist (terminator included) is spliced over the old one and the
    /// remaining runlist region is zero-padded so the attribute length is
    /// unchanged. PURE on-disk surgery: reads the record raw, mutates the
    /// fixed-up bytes, and writes them back via `writeRawRecord` (which
    /// re-applies the USA fix-up). Returns the original first extent's LCN.
    @discardableResult
    private func patchFirstDataRunLCN(
        volume: Volume,
        recordNumber: UInt64,
        newStartLCN: UInt64
    ) async throws -> UInt64 {
        let mft = await volume.mft()
        let record = try await mft.record(at: recordNumber)
        var bytes = record.bytes   // already USA-fixed-up

        // Locate the unnamed non-resident $DATA attribute by walking the
        // attribute stream by hand.
        let first = Int(record.firstAttributeOffset)
        let used = Int(record.usedSize)
        var c = first
        var dataStart = -1
        while c + 8 <= used {
            let type = try bytes.readU32LE(at: c)
            if type == 0xFFFF_FFFF { break }
            let len = Int(try bytes.readU32LE(at: c + 4))
            let nonResident = try bytes.readU8(at: c + 8)
            let nameLen = try bytes.readU8(at: c + 9)
            if type == AttributeType.data.rawValue && nonResident == 1 && nameLen == 0 {
                dataStart = c
                break
            }
            guard len > 0 else { break }
            c += len
        }
        guard dataStart >= 0 else {
            throw NTFSError.corruptOnDisk(
                description: "patchFirstDataRunLCN: no unnamed non-resident $DATA in record \(recordNumber)"
            )
        }

        // The runlist spans [dataRunsOffset, attrLen) within the attribute.
        let attrLen = Int(try bytes.readU32LE(at: dataStart + 4))
        let runsOff = Int(try bytes.readU16LE(at: dataStart + 32))
        let runStart = dataStart + runsOff
        let runEnd = dataStart + attrLen
        let runRegion = runEnd - runStart
        guard runRegion > 0 else {
            throw NTFSError.corruptOnDisk(
                description: "patchFirstDataRunLCN: empty runlist region in record \(recordNumber)"
            )
        }

        // Decode the existing runlist with the project's real decoder.
        let oldRunBytes = Data(bytes[(bytes.startIndex + runStart)..<(bytes.startIndex + runEnd)])
        var extents = try DataRun.decode(oldRunBytes)
        guard let firstExtent = extents.first, !firstExtent.isSparse else {
            throw NTFSError.corruptOnDisk(
                description: "patchFirstDataRunLCN: first extent missing or sparse in record \(recordNumber)"
            )
        }
        let originalLCN = firstExtent.startLCN ?? 0

        // Replace extent[0]'s startLCN, keeping its cluster count.
        extents[0] = Extent(startLCN: newStartLCN, clusterCount: firstExtent.clusterCount)

        // Re-encode with the REAL encoder (auto-selects a wide-enough offset
        // width); it already appends the 0x00 terminator.
        let newRun = await volume._encodeRunlistForTesting(extents)
        guard newRun.count <= runRegion else {
            throw NTFSError.unsupportedFeature(
                description: "patchFirstDataRunLCN: re-encoded runlist \(newRun.count) bytes exceeds region \(runRegion); pick a smaller new LCN"
            )
        }

        // Splice the new runlist over the old region; zero-pad the remainder so
        // the attribute length stays exactly the same.
        for (i, b) in newRun.enumerated() {
            bytes[bytes.startIndex + runStart + i] = b
        }
        for i in newRun.count..<runRegion {
            bytes[bytes.startIndex + runStart + i] = 0x00
        }

        try await mft.writeRawRecord(at: recordNumber, postFixupBytes: bytes)
        return originalLCN
    }

    // MARK: - Case 1: all-allocated (clean)

    func testAllAllocatedRunlistIsClean() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let recordNumber: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)
            (recordNumber, _) = try await createNonResidentFile(
                volume: volume, named: "clean-nonres.bin"
            )
        }

        // Re-open read-only and run the per-record audit.
        let volume = try await reopenReadOnly(path)
        let audit = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordNumber)

        XCTAssertFalse(audit.dataResident, "payload should be non-resident (has a runlist)")
        XCTAssertFalse(audit.extents.isEmpty, "non-resident $DATA must have extents")
        XCTAssertTrue(audit.isClean, "freshly-written file should be clean: \(audit.anomalies)")
        XCTAssertEqual(audit.freeButReferencedCount, 0)
        XCTAssertEqual(audit.outOfRangeCount, 0)

        // Every referenced cluster must be accounted for as allocated.
        let allocated = audit.extents.reduce(UInt64(0)) { $0 + $1.allocatedClusters }
        XCTAssertGreaterThan(audit.totalClustersReferenced, 0, "must reference at least one cluster")
        XCTAssertEqual(
            allocated, audit.totalClustersReferenced,
            "all referenced clusters should be ALLOCATED in $Bitmap"
        )

        // Whole-volume sweep must also be clean with zero double-allocations.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(sweep.isClean, "whole-volume sweep should be clean: \(sweep.perRecordAnomalies)")
        XCTAssertEqual(sweep.doubleAllocatedClusters, 0)
        XCTAssertEqual(sweep.freeButReferencedClusters, 0)
        XCTAssertEqual(sweep.outOfRangeClusters, 0)
        XCTAssertGreaterThan(sweep.filesChecked, 0)
    }

    // MARK: - Case 2: freed-but-referenced cluster (flagged)

    func testFreedButReferencedClusterIsFlagged() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let recordNumber: UInt64
        let leakedLCN: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)
            (recordNumber, _) = try await createNonResidentFile(
                volume: volume, named: "leaked-nonres.bin"
            )

            // Capture one of the file's allocated clusters, then mark JUST that
            // cluster FREE in $Bitmap WITHOUT touching the file's runlist. The
            // file still references it; the bitmap now says it's free — exactly
            // the over-free smoking gun the audit exists to catch.
            let pre = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordNumber)
            leakedLCN = try firstAllocatedLCN(pre)
            // freeClusters touches ONLY the $Bitmap (verified in Volume.swift):
            // it does not rewrite the file's runlist.
            try await volume.freeClusters(Extent(startLCN: leakedLCN, clusterCount: 1))
        }

        // Re-open read-only and audit: the runlist still points at `leakedLCN`
        // but the bitmap says it's free.
        let volume = try await reopenReadOnly(path)
        let audit = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordNumber)

        XCTAssertFalse(audit.isClean, "a free-but-referenced cluster must fail clean")
        XCTAssertGreaterThanOrEqual(
            audit.freeButReferencedCount, 1,
            "the cluster freed in $Bitmap but still referenced must be flagged"
        )
        XCTAssertFalse(audit.anomalies.isEmpty, "an anomaly string must describe the fault")
        XCTAssertTrue(
            audit.anomalies.contains { $0.contains("FREE in $Bitmap") },
            "anomaly should mention FREE in $Bitmap: \(audit.anomalies)"
        )

        // Whole-volume sweep must surface the same fault.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertFalse(sweep.isClean, "sweep must fail with a free-but-referenced cluster")
        XCTAssertGreaterThanOrEqual(sweep.freeButReferencedClusters, 1)
    }

    // MARK: - Case 3: out-of-range LCN (flagged)

    func testOutOfRangeLCNIsFlagged() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let recordNumber: UInt64
        let totalClusters: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)
            (recordNumber, _) = try await createNonResidentFile(
                volume: volume, named: "oob-nonres.bin"
            )
            totalClusters = await volume.totalClusterCount

            // Byte-patch the file's $DATA so its first run's startLCN lands at
            // totalClusters + 5 — guaranteed >= the volume cluster count, so the
            // audit classifies those clusters OUT_OF_RANGE. Keeps the runlist
            // fully decodable (only the offset field changes).
            let oob = totalClusters + 5
            try await patchFirstDataRunLCN(
                volume: volume, recordNumber: recordNumber, newStartLCN: oob
            )
        }

        let volume = try await reopenReadOnly(path)
        let reopenedTotalClusters = await volume.totalClusterCount
        XCTAssertEqual(reopenedTotalClusters, totalClusters, "geometry unchanged by the patch")
        let audit = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordNumber)

        XCTAssertFalse(audit.isClean, "an out-of-range LCN must fail clean")
        XCTAssertGreaterThanOrEqual(
            audit.outOfRangeCount, 1,
            "the run pointing past the volume must be flagged out-of-range"
        )
        XCTAssertTrue(
            audit.anomalies.contains { $0.contains("out of volume range") },
            "anomaly should mention out-of-range: \(audit.anomalies)"
        )

        // Whole-volume sweep agrees.
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertFalse(sweep.isClean)
        XCTAssertGreaterThanOrEqual(sweep.outOfRangeClusters, 1)
    }

    // MARK: - Case 4: double-allocation (flagged)

    func testDoubleAllocatedClusterIsFlagged() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let recordA: UInt64
        let recordB: UInt64
        let sharedLCN: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)

            (recordA, _) = try await createNonResidentFile(volume: volume, named: "dup-a.bin")
            (recordB, _) = try await createNonResidentFile(volume: volume, named: "dup-b.bin")

            // Take one of A's allocated clusters, then byte-patch B's $DATA so
            // B's first run ALSO points at it. Both in-use base records now
            // claim the same physical cluster — the cross-record double-alloc
            // the whole-volume sweep detects.
            let auditA = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordA)
            sharedLCN = try firstAllocatedLCN(auditA)
            try await patchFirstDataRunLCN(
                volume: volume, recordNumber: recordB, newStartLCN: sharedLCN
            )
        }

        let volume = try await reopenReadOnly(path)

        // Confirm both records really reference the shared cluster.
        let a = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordA)
        let b = try await volume.auditDataRunlistAgainstBitmap(recordNumber: recordB)
        XCTAssertTrue(
            a.extents.contains { $0.startLCN == sharedLCN },
            "record A should still reference the shared LCN \(sharedLCN)"
        )
        XCTAssertTrue(
            b.extents.contains { $0.startLCN == sharedLCN },
            "record B should now reference the shared LCN \(sharedLCN)"
        )

        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()
        XCTAssertFalse(sweep.isClean, "a cluster claimed by two records must fail clean")
        XCTAssertGreaterThanOrEqual(
            sweep.doubleAllocatedClusters, 1,
            "the cluster referenced by both A and B must be flagged double-allocated"
        )
        XCTAssertTrue(
            sweep.perRecordAnomalies.contains { rec in
                rec.anomalies.contains { $0.contains("double-allocated") }
            },
            "a per-record anomaly should mention double-allocated: \(sweep.perRecordAnomalies)"
        )
    }

    // MARK: - On-disk raw-record surgery (cases 5 & 6)

    /// Byte offset of MFT record `recordNumber` for a fixture whose $MFT is
    /// contiguous from `boot.mftCluster`. The records these tests touch are
    /// freshly-created low user records (recnum ~16-20) that always live inside
    /// the first $MFT extent, so the contiguous offset is exact. Mirrors
    /// `MFT.mftRecordByteOffset`'s record-0 / first-extent fast path.
    private func contiguousRecordByteOffset(
        volume: Volume, recordNumber: UInt64
    ) -> UInt64 {
        volume.mftByteOffset &+ recordNumber &* UInt64(volume.mftRecordSizeBytes)
    }

    /// Overwrite MFT record `recordNumber` on disk with an all-zero record.
    /// This synthesizes a zeroed/uninitialized slot whose magic is
    /// `0x00000000`, exactly the shape of the allocated-but-never-used $MFT
    /// tail on real hardware. `mft.record(at:)` will throw
    /// `corruptOnDisk("...magic 0x00000000")` for it. Direct device write
    /// (not `writeRawRecord`) because an all-zero record has no valid USA for
    /// the reverse-fixup path.
    private func zeroOutRecordOnDisk(
        volume: Volume, recordNumber: UInt64
    ) async throws {
        let recordSize = Int(volume.mftRecordSizeBytes)
        let offset = contiguousRecordByteOffset(volume: volume, recordNumber: recordNumber)
        try await volume.device.write(offset: offset, bytes: Data(count: recordSize))
    }

    /// Stamp the on-disk magic of MFT record `recordNumber` to 'BAAD' (the
    /// marker NTFS writes when it detects corruption). The record keeps its
    /// valid USA, so `MFTRecord.parse` reaches the magic check and throws
    /// `corruptOnDisk("MFT record magic is 'BAAD' ...")` — a GENUINE unreadable
    /// record whose error string deliberately does NOT contain
    /// "magic 0x00000000", so it is NOT mistaken for a zeroed tail slot.
    private func stampBAADOnDisk(
        volume: Volume, recordNumber: UInt64
    ) async throws {
        let recordSize = Int(volume.mftRecordSizeBytes)
        let offset = contiguousRecordByteOffset(volume: volume, recordNumber: recordNumber)
        var raw = try await volume.device.read(offset: offset, length: recordSize)
        // 'BAAD' on disk = bytes 0x42 0x41 0x41 0x44 (LE u32 0x44414142).
        raw[raw.startIndex + 0] = 0x42
        raw[raw.startIndex + 1] = 0x41
        raw[raw.startIndex + 2] = 0x41
        raw[raw.startIndex + 3] = 0x44
        try await volume.device.write(offset: offset, bytes: raw)
    }

    // MARK: - Case 5 (AC-7): zeroed MFT tail slot is skipped, not unreadable

    /// A zeroed/uninitialized MFT slot inside the swept range must be treated
    /// as a FREE/never-used slot (skipped), NOT counted as an unreadable
    /// record. Proves the `magic 0x00000000` catch in
    /// `auditAllDataRunlistsAgainstBitmap`. Hardware symptom this guards
    /// against: a CLEAN 4 TB volume reporting "Unreadable records: 13" for the
    /// empty $MFT tail (recnums 104179-104191).
    func testZeroedMFTTailSlotIsSkippedNotUnreadable() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let zeroedRN: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)

            // A real non-resident file so the sweep has genuine runlist content
            // to verify in addition to the zeroed slot.
            _ = try await createNonResidentFile(volume: volume, named: "with-tail.bin")

            // Claim a fresh slot, then zero it on disk so it looks like the
            // uninitialized $MFT tail. It is still within the MFT logical range
            // (it was allocatable), so the sweep WILL visit it.
            let mft = await volume.mft()
            zeroedRN = try await mft.findFreeRecordNumber()
            try await zeroOutRecordOnDisk(volume: volume, recordNumber: zeroedRN)

            // Sanity: reading that slot now throws the zeroed-magic error.
            do {
                _ = try await mft.record(at: zeroedRN)
                XCTFail("zeroed slot \(zeroedRN) should not parse")
            } catch let NTFSError.corruptOnDisk(desc) {
                XCTAssertTrue(
                    desc.contains("magic 0x00000000"),
                    "zeroed slot must throw the magic-0x00000000 error, got: \(desc)"
                )
            }
        }

        let volume = try await reopenReadOnly(path)
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()

        // AC-7: the zeroed tail slot is SKIPPED, never counted unreadable.
        XCTAssertTrue(
            sweep.unreadableRecords.isEmpty,
            "zeroed/uninitialized MFT slot must not be counted unreadable: \(sweep.unreadableRecords)"
        )
        XCTAssertFalse(
            sweep.unreadableRecords.contains(zeroedRN),
            "the zeroed slot \(zeroedRN) must not appear in unreadableRecords"
        )
        // With no other anomalies, the whole-volume audit is clean — which is
        // exactly the verdict `verify --deep` now emits (deepFailed = !isClean).
        XCTAssertTrue(
            sweep.isClean,
            "a clean volume with only a zeroed tail slot must audit clean: \(sweep.perRecordAnomalies)"
        )
        XCTAssertGreaterThan(sweep.filesChecked, 0)
    }

    // MARK: - Case 6 (AC-8): genuinely-unreadable record fails clean

    /// A record with a valid FILE magic flipped to 'BAAD' genuinely fails to
    /// parse with an error OTHER than the zeroed-slot `magic 0x00000000` case,
    /// so it MUST land in `unreadableRecords` and force `isClean == false`.
    ///
    /// `Verify.swift`'s deep verdict is now `deepFailed = !audit.isClean`, so
    /// asserting `isClean == false` here is equivalent to asserting the
    /// `verify --deep` run fails: the two are tied together by construction
    /// (AC-8). We assert via the audit because `Verify.run()` opens a device by
    /// path and isn't unit-testable in this package.
    func testGenuinelyUnreadableRecordFailsClean() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)

        let badRN: UInt64
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let volume = try await Volume(device: device)

            // Create a real file, then corrupt JUST its magic to 'BAAD'. The
            // slot stays IN_USE-shaped on disk but parsing throws before the
            // flags are read.
            (badRN, _) = try await createNonResidentFile(volume: volume, named: "baad.bin")
            try await stampBAADOnDisk(volume: volume, recordNumber: badRN)

            // Sanity: it now throws a NON-zeroed-slot corruption error.
            let mft = await volume.mft()
            do {
                _ = try await mft.record(at: badRN)
                XCTFail("'BAAD' record \(badRN) should not parse")
            } catch let NTFSError.corruptOnDisk(desc) {
                XCTAssertTrue(desc.contains("BAAD"), "expected a BAAD error, got: \(desc)")
                XCTAssertFalse(
                    desc.contains("magic 0x00000000"),
                    "BAAD must NOT look like a zeroed slot: \(desc)"
                )
            }
        }

        let volume = try await reopenReadOnly(path)
        let sweep = try await volume.auditAllDataRunlistsAgainstBitmap()

        // AC-8: a genuine unreadable record is recorded AND fails cleanliness.
        XCTAssertTrue(
            sweep.unreadableRecords.contains(badRN),
            "the 'BAAD' record \(badRN) must appear in unreadableRecords: \(sweep.unreadableRecords)"
        )
        XCTAssertFalse(
            sweep.isClean,
            "a genuinely-unreadable record must fail the volume audit clean"
        )
        // Tie-in to Verify's verdict: deepFailed = !audit.isClean, so this
        // false isClean is exactly the deep-verify FAIL path.
    }
}
