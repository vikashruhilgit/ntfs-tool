import XCTest
@testable import NTFSCore

/// v0.5 Fix B Step 4 — `$DATA` (0x80) migration unit tests (AC-6, AC-7, AC-8).
///
/// Exercises the unnamed-`$DATA` overflow migration write path end-to-end.
/// When a file's non-resident `$DATA` runlist outgrows the slack in its base
/// MFT record (the user-reported hardware abort at ~file 350 of a bulk
/// `cp -r`), the driver migrates `$DATA` into a freshly-allocated extension
/// record and adds a resident `$ATTRIBUTE_LIST` to the base.
///
/// Unlike the sibling `$INDEX_ALLOCATION` (0xA0) tests in
/// `AttributeListMigrationTests`, AC-6/AC-7 here drive the overflow
/// **organically** through the public `writeFile(at:totalSize:nextChunk:)`
/// streaming-write API: the disk is deliberately fragmented into a
/// swiss-cheese bitmap so the file's runlist fans out into hundreds of
/// one-cluster extents, pushing the serialized `$DATA` attribute past the
/// base record's slack and tripping the migration. No synthetic
/// hand-built attribute bytes and no direct migrate-helper call are needed.
final class DataMigrationTests: XCTestCase {

    // MARK: - fixture / walk helpers (mirror AttributeListMigrationTests)

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Count every IN_USE MFT slot. Used for the "no orphan slot leaked"
    /// assertions (mirror of `AttributeListMigrationTests.countInUseRecords`).
    private func countInUseRecords(mft: MFT, maxRN: UInt64 = 512) async throws -> Int {
        var count = 0
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.isInUse { count += 1 }
        }
        return count
    }

    /// Find the extension MFT record whose `baseFileReference` points at
    /// `baseRN`. The migration allocates this lazily so the slot number
    /// depends on the fixture's free-MFT state at trigger time.
    private func findExtensionRecord(
        for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 512
    ) async throws -> UInt64? {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.baseFileReference != 0,
               (rec.baseFileReference & mask) == (baseRN & mask) {
                return rn
            }
        }
        return nil
    }

    /// Deterministic content generator so a multi-megabyte payload can be
    /// byte-compared on read-back without holding a reference copy.
    private static func contentByte(at i: UInt64) -> UInt8 {
        UInt8((i &* 31 &+ 7) & 0xFF)
    }

    /// Carve the free space into a swiss-cheese bitmap (max contiguous run
    /// == 1 cluster) so the subsequent `writeFile` is forced to allocate a
    /// long, highly-fragmented runlist via `allocateClustersFragmented`.
    /// Returns the number of free clusters remaining after carving.
    private func fragmentFreeSpace(_ volume: Volume) async throws -> UInt64 {
        var singles: [Extent] = []
        while let e = try? await volume.allocateClusters(1) {
            singles.append(e)
            if singles.count > 4096 { break }   // safety bound
        }
        // Free every other single — leaves alternating allocated/free
        // clusters so no run longer than one cluster survives.
        for (i, e) in singles.enumerated() where i % 2 == 0 {
            try await volume.freeClusters(e)
        }
        return try await volume.allocationStats().freeClusters
    }

    /// Index-by-index byte comparison of `data` against the deterministic
    /// `contentByte(at:)` generator. Returns the first divergent byte index,
    /// or nil if every byte matches. Avoids `Data.withUnsafeBytes`
    /// (ambiguous overload) and large reference copies.
    private func firstContentMismatch(in data: Data) -> Int? {
        let base = data.startIndex
        for i in 0..<data.count where data[base + i] != Self.contentByte(at: UInt64(i)) {
            return i
        }
        return nil
    }

    /// Drive a fully-organic non-resident `$DATA` overflow on a fragmented
    /// volume: create a file, fragment the disk, then stream
    /// `clusters` clusters' worth of deterministic content through
    /// `writeFile`. The 260-cluster default lands in the migration-success
    /// window measured on `small.img` (4 KiB clusters, 1 KiB MFT records):
    /// the resulting ~780-byte runlist overflows the base record's ~752-byte
    /// slack yet still fits a fresh extension record. Returns the file's
    /// record number and the exact byte length written.
    private func driveDataOverflow(
        volume: Volume,
        named name: String,
        inDirectory parentRN: UInt64 = 5,
        clusters: UInt64 = 260
    ) async throws -> (recordNumber: UInt64, byteCount: UInt64) {
        let rn = try await volume.createFile(named: name, inDirectory: parentRN)
        let freeAfterCarve = try await fragmentFreeSpace(volume)
        XCTAssertGreaterThan(
            freeAfterCarve, clusters + 1,
            "fixture has too little free space to fragment for a \(clusters)-cluster overflow"
        )

        let total = Int(clusters * UInt64(volume.bytesPerCluster)) - 17  // non-cluster-aligned tail
        // Precompute the full deterministic payload OUTSIDE the streaming
        // closure (mirrors StreamingAndLargeIndexTests) so the closure captures
        // only Sendable values and feeds chunks via `subdata`.
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
        return (rn, UInt64(total))
    }

    // MARK: - AC-6: end-to-end $DATA migration on organic overflow

    func testDataAttributeMigrationOnOverflow() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let mftPre = await volume.mft()
        let inUseBefore = try await countInUseRecords(mft: mftPre)

        // Organic overflow: createFile + fragment + streaming writeFile.
        let (rn, total) = try await driveDataOverflow(volume: volume, named: "data-overflow.bin")

        let mft = await volume.mft()
        let baseRecord = try await mft.record(at: rn)
        let baseAttrs = try baseRecord.attributes()

        // (a) Base record gained $ATTRIBUTE_LIST and no longer carries an
        //     in-base unnamed $DATA (neither resident nor non-resident).
        XCTAssertTrue(
            baseAttrs.contains { $0.rawType == AttributeType.attributeList.rawValue },
            "base record \(rn) should carry a resident $ATTRIBUTE_LIST after $DATA migration"
        )
        XCTAssertFalse(
            baseAttrs.contains { $0.type == .data && $0.nameOrEmpty == "" },
            "base record \(rn) should NOT still hold an unnamed $DATA after migration"
        )

        // (b) An extension record exists holding the migrated $DATA with the
        //     canonical baseFileReference packing (baseSeq << 48 | baseRN).
        guard let extRN = try await findExtensionRecord(for: rn, in: volume) else {
            return XCTFail("expected exactly one extension MFT record after $DATA migration")
        }
        let extRecord = try await mft.record(at: extRN)
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        let expectedBaseRef = (UInt64(baseRecord.sequenceNumber) << 48) | (rn & mask)
        XCTAssertEqual(
            extRecord.baseFileReference, expectedBaseRef,
            "extension record's baseFileReference must pack (baseSeq << 48) | (baseRN & 0xFFFFFFFFFFFF)"
        )
        // The extension must actually hold a non-resident unnamed $DATA.
        let extAttrs = try extRecord.attributes()
        XCTAssertTrue(
            extAttrs.contains {
                if $0.type == .data, $0.nameOrEmpty == "", case .nonResident = $0.value { return true }
                return false
            },
            "extension record \(extRN) must hold the migrated non-resident unnamed $DATA"
        )

        // (c) resolveAttribute walks $ATTRIBUTE_LIST and surfaces the
        //     migrated $DATA from the extension record.
        let resolved = try await volume.resolveAttribute(recordNumber: rn, type: .data, name: "")
        XCTAssertNotNil(
            resolved,
            "resolveAttribute(.data, \"\") must follow $ATTRIBUTE_LIST to the extension record"
        )

        // (e) Exactly TWO extra MFT records consumed since the empty fixture:
        //     the file's own base record (createFile) + the single migration
        //     extension. `fragmentFreeSpace` only touches the cluster bitmap,
        //     never MFT slots, so this delta is deterministic. A migration
        //     orphan leak would push the delta to 3+. Checked before read-back
        //     so we catch any double-allocation in the transactional path.
        let inUseAfter = try await countInUseRecords(mft: mft)
        XCTAssertEqual(
            inUseAfter - inUseBefore, 2,
            "expected exactly 2 new MFT slots (file base record + 1 migration extension); got delta \(inUseAfter - inUseBefore)"
        )

        // (d) readFile returns the written content byte-identical, both
        //     in-memory and after a fresh reopen from disk (durable shape).
        let inMemory = try await volume.readFile(at: rn)
        XCTAssertEqual(UInt64(inMemory.count), total, "in-memory read-back length mismatch")

        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let readBack = try await reopen.readFile(at: rn)
        XCTAssertEqual(UInt64(readBack.count), total, "post-reopen read-back length mismatch")
        let firstMismatch = firstContentMismatch(in: readBack)
        XCTAssertNil(firstMismatch, "post-migration read-back diverges at byte \(firstMismatch ?? -1)")

        // (AC-4-style byte-layout) The on-disk $ATTRIBUTE_LIST must reference
        // the extension record for the migrated $DATA and the base for the
        // others.
        guard let attrListAttr = try await reopen.resolveAttribute(
            recordNumber: rn, type: .attributeList, name: nil
        ) else {
            return XCTFail("base \(rn) lacks resolvable $ATTRIBUTE_LIST after reopen")
        }
        guard case let .resident(listBytes, _) = attrListAttr.value else {
            return XCTFail("$ATTRIBUTE_LIST expected resident in v0.5 (non-resident deferred)")
        }
        let entries = try AttributeListEntry.parseAll(in: listBytes)
        XCTAssertGreaterThan(entries.count, 1, "$ATTRIBUTE_LIST should describe several attributes")
        let baseRef = (UInt64(baseRecord.sequenceNumber) << 48) | (rn & mask)
        let extRef  = (UInt64(extRecord.sequenceNumber) << 48) | (extRN & mask)
        var sawMigrant = false
        for e in entries {
            if e.attributeType == AttributeType.data.rawValue && e.name.isEmpty {
                sawMigrant = true
                XCTAssertEqual(
                    e.mftReference, extRef,
                    "migrated unnamed $DATA entry must reference the extension record"
                )
            } else {
                XCTAssertEqual(
                    e.mftReference, baseRef,
                    "non-migrant entry 0x\(String(e.attributeType, radix: 16)) must point at the base record"
                )
            }
        }
        XCTAssertTrue(sawMigrant, "$ATTRIBUTE_LIST must include the migrated unnamed $DATA entry")
    }

    // MARK: - AC-7: round-trip on reopen + deferred subsequent write

    func testDataMigrationRoundTripReopen() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let (rn, total) = try await driveDataOverflow(volume: volume, named: "roundtrip.bin")

        // Sanity: migration actually fired (base carries $ATTRIBUTE_LIST).
        let baseAttrs = try (try await (await volume.mft()).record(at: rn)).attributes()
        XCTAssertTrue(
            baseAttrs.contains { $0.rawType == AttributeType.attributeList.rawValue },
            "precondition: migration must have fired (base needs $ATTRIBUTE_LIST)"
        )

        // Reopen from disk and confirm full content reads back byte-identical
        // through the $ATTRIBUTE_LIST-aware read path.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let readBack = try await reopen.readFile(at: rn)
        XCTAssertEqual(UInt64(readBack.count), total, "reopen read-back length mismatch")
        let firstMismatch = firstContentMismatch(in: readBack)
        XCTAssertNil(firstMismatch, "reopen read-back diverges at byte \(firstMismatch ?? -1)")

        // A SUBSEQUENT write to the already-migrated file is intentionally
        // DEFERRED in v0.5: it must throw a clean unsupportedFeature whose
        // description names $ATTRIBUTE_LIST — NOT corrupt the on-disk record.
        // Verify via BOTH public write entry points.
        let extra = Data(repeating: 0xC3, count: 4096)

        var writeThrew = false
        do {
            try await reopen.write(at: rn, offset: 0, bytes: extra)
        } catch NTFSError.unsupportedFeature(let desc) {
            writeThrew = true
            XCTAssertTrue(
                desc.contains("$ATTRIBUTE_LIST"),
                "deferred-write error must mention $ATTRIBUTE_LIST; got: \(desc)"
            )
        }
        XCTAssertTrue(writeThrew, "write() on a migrated file must throw unsupportedFeature (deferred), not succeed")

        var writeFileThrew = false
        do {
            var sent = false
            try await reopen.writeFile(at: rn, totalSize: UInt64(extra.count)) {
                if sent { return Data() }
                sent = true
                return extra
            }
        } catch NTFSError.unsupportedFeature(let desc) {
            writeFileThrew = true
            XCTAssertTrue(
                desc.contains("$ATTRIBUTE_LIST"),
                "deferred-writeFile error must mention $ATTRIBUTE_LIST; got: \(desc)"
            )
        }
        XCTAssertTrue(writeFileThrew, "writeFile() on a migrated file must throw unsupportedFeature (deferred)")

        // The deferred write must NOT have damaged the file: content still
        // reads back byte-identical after the failed attempts.
        let afterFailedWrites = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let stillReadable = try await afterFailedWrites.readFile(at: rn)
        XCTAssertEqual(
            UInt64(stillReadable.count), total,
            "deferred-write rejection must leave the migrated file intact (length unchanged)"
        )
    }

    // MARK: - AC-8: unsupported overflow type throws clean, no slot leak

    func testUnsupportedOverflowTypeStillThrowsClean() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // A real, freshly-created file to target — its base record exists and
        // is in use, so the type guard (not a "missing record" error) is what
        // fires.
        let rn = try await volume.createFile(named: "unsupported.txt", inDirectory: 5)

        let mft = await volume.mft()
        let inUseBefore = try await countInUseRecords(mft: mft)

        // Drive the dispatcher with an overflowDescription carrying a type
        // that is NEITHER 0xA0 NOR 0x80 (here 0x90 = $INDEX_ROOT). The guard
        // must run BEFORE any MFT allocation, so no slot can leak.
        var threw = false
        do {
            try await volume.migrateIndexAllocationOnOverflow(
                baseRecordNumber: rn,
                overflowDescription: "would overflow record (synthetic test invocation, type 0x90)"
            )
        } catch NTFSError.unsupportedFeature(let desc) {
            threw = true
            XCTAssertTrue(
                desc.contains("0x90"),
                "unsupported-type error must surface the offending hex (0x90); got: \(desc)"
            )
            XCTAssertTrue(
                desc.contains("not yet implemented"),
                "unsupported-type error should name the unimplemented migrate-X path; got: \(desc)"
            )
        }
        XCTAssertTrue(threw, "a non-0xA0/non-0x80 overflow type must throw unsupportedFeature")

        // The type guard runs before allocateMFTRecord — IN_USE count must be
        // identical, proving no extension slot was leaked.
        let inUseAfter = try await countInUseRecords(mft: mft)
        XCTAssertEqual(
            inUseBefore, inUseAfter,
            "unsupported-type migration attempt must NOT leak an MFT slot (guard runs pre-allocation)"
        )
    }

    // MARK: - v0.7.4: chkdsk "attribute records are unsorted"

    /// Windows `chkdsk` requires the attributes *within* an MFT record to
    /// appear in ascending `(type, name, startingVCN)` order. Both migration
    /// builders used to append the new `$ATTRIBUTE_LIST` (type 0x20) to the
    /// end of the stream, placing it after `$FILE_NAME` (0x30).
    ///
    /// A read-only `chkdsk` on a 15,997-record hardware volume flagged
    /// "Attribute records for file record segment N are unsorted" on every
    /// migrated base record — while our own `verify --deep` passed the same
    /// volume clean, because our reader iterates attributes without caring
    /// about order. This asserts the invariant our reader can't feel.
    func testMigratedBaseRecordAttributesAreCanonicallySorted() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let (rn, _) = try await driveDataOverflow(volume: volume, named: "sorted-attrs.bin")

        // Re-read from disk so we assert the persisted byte order, not an
        // in-memory view.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let record = try await reopen.mft().record(at: rn)
        let attrs = try record.attributes()

        XCTAssertTrue(
            attrs.contains { $0.rawType == AttributeType.attributeList.rawValue },
            "precondition: record \(rn) must be migrated for this test to mean anything"
        )

        let types = attrs.map(\.rawType)
        XCTAssertEqual(
            types, types.sorted(),
            "attributes must be stored in ascending type order; got \(types.map { String(format: "0x%02X", $0) })"
        )

        // $ATTRIBUTE_LIST (0x20) specifically must precede $FILE_NAME (0x30) —
        // the exact inversion chkdsk flagged.
        if let listIdx = types.firstIndex(of: AttributeType.attributeList.rawValue),
           let nameIdx = types.firstIndex(of: AttributeType.fileName.rawValue) {
            XCTAssertLessThan(
                listIdx, nameIdx,
                "$ATTRIBUTE_LIST (0x20) must be stored before $FILE_NAME (0x30)"
            )
        }
    }

    // MARK: - v0.7.4: every public read entry point handles a migrated file

    /// Regression guard for the hardware-found bug where `readFileSlice`
    /// rejected any record carrying an `$ATTRIBUTE_LIST` outright, while
    /// `readFile` resolved it correctly. The two paths disagreed, so a
    /// migrated file was readable whole but not streamable — breaking
    /// `ntfsctl cat`, `ntfsctl cp --from-volume`, and the FSKit extension's
    /// kernel read callback, all of which stream.
    ///
    /// The pre-existing `readFileSlice` tests all used small non-migrated
    /// files, so nothing covered the migrated shape on the streaming path.
    /// This test asserts the two entry points agree on the SAME migrated
    /// record: any future divergence fails here rather than on a USB stick.
    func testMigratedFileReadsBackThroughEveryReadEntryPoint() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let (rn, total) = try await driveDataOverflow(volume: volume, named: "slice-migrated.bin")

        // Precondition: this really is the migrated shape. Without this the
        // test could pass green against a non-migrated file and prove nothing.
        let baseAttrs = try await volume.mft().record(at: rn).attributes()
        XCTAssertTrue(
            baseAttrs.contains { $0.rawType == AttributeType.attributeList.rawValue },
            "fixture precondition: record \(rn) must carry $ATTRIBUTE_LIST for this to test the migrated path"
        )

        // Read back from a fresh reopen so we exercise the on-disk shape.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let whole = try await reopen.readFile(at: rn)
        XCTAssertEqual(UInt64(whole.count), total, "readFile length mismatch on migrated file")

        // (a) Chunked streaming reassembly must equal the whole-file read.
        // 64 KiB chunks cross extent boundaries repeatedly on the swiss-cheese
        // bitmap, so this walks the merged runlist rather than one extent.
        var assembled = Data()
        var offset: UInt64 = 0
        while offset < total {
            let chunk = try await reopen.readFileSlice(
                at: rn, offset: offset, length: 1 << 16
            )
            XCTAssertFalse(
                chunk.isEmpty,
                "readFileSlice returned empty at offset \(offset) of \(total) — streaming stalled"
            )
            assembled.append(chunk)
            offset += UInt64(chunk.count)
        }
        XCTAssertEqual(
            UInt64(assembled.count), total,
            "streamed reassembly length \(assembled.count) != readFile length \(total)"
        )
        let mismatch = firstContentMismatch(in: assembled)
        XCTAssertNil(mismatch, "streamed reassembly diverges at byte \(mismatch ?? -1)")

        // (b) Windowed reads must agree with the same window of readFile,
        // including a non-cluster-aligned straddle and the final partial
        // cluster (the tail is deliberately 17 bytes short of aligned).
        let wholeBase = whole.startIndex
        let windows: [(UInt64, Int)] = [
            (0, 10),                       // head
            (4095, 4098),                  // straddles a cluster boundary
            (total / 2 + 7, 1 << 15),      // unaligned mid-file span
            (total - 17, 17),              // exact tail
            (total - 1, 64),               // tail, over-requested
        ]
        for (off, len) in windows {
            let slice = try await reopen.readFileSlice(at: rn, offset: off, length: len)
            let expectedEnd = min(off &+ UInt64(len), total)
            let expected = whole.subdata(
                in: (wholeBase + Int(off))..<(wholeBase + Int(expectedEnd))
            )
            XCTAssertEqual(
                slice, expected,
                "readFileSlice(offset: \(off), length: \(len)) disagrees with readFile's same window"
            )
        }

        // (c) Past-EOF is empty, not an error — the FSKit read callback
        // relies on this to terminate.
        let pastEOF = try await reopen.readFileSlice(at: rn, offset: total, length: 4096)
        XCTAssertTrue(pastEOF.isEmpty, "read at EOF must return empty, got \(pastEOF.count) bytes")
    }
}
