import XCTest
@testable import NTFSCore

/// v0.5 follow-up — lifting the post-migration `$INDEX_ALLOCATION` (0xA0)
/// growth ceiling that capped a real-hardware `cp -r` at ~file 6,139.
///
/// Root cause (confirmed against `main` @ 751cd9f via a controlled probe):
/// the pre-fix `rewriteParentForLeafSplit` rewrote `$INDEX_ALLOCATION:$I30`
/// in the BASE record unconditionally. After the original ~350-file
/// migration moves it to an extension record (and drops `$ATTRIBUTE_LIST`
/// on the base in its place), the very next leaf split that must grow the
/// attribute threw `corruptOnDisk: rewriteEntireAttribute: target type
/// 0x000000A0 name '$I30' not found` — the directory could not grow past
/// migration at all. On the 4 TB hardware the resident runlist stayed
/// compact (next-fit, few extents) until ~6,139 files; migration first
/// fired there and immediately hit this wall.
///
/// The fix makes the split path extension-aware: it locates the migrated
/// attribute via the base's `$ATTRIBUTE_LIST`, rewrites it in the
/// extension's bytes, and commits the extension record BEFORE the base
/// (transactional discipline matching `migrateAttributeOnOverflow`). A
/// secondary corruption — the cascade → root-overflow → height-grow path
/// dropped `extraRecordWrites` and orphaned one INDX block's worth of
/// entries (the pre-existing `splitLeafAndPromote` guard caught it as
/// `post-split state mismatch missing=36`) — is fixed by threading
/// `extraRecordWrites` through the height-grow return path.
///
/// These tests exercise that path on small.img (the only fixture; 4 MiB
/// is too small to fragment the runlist enough to trigger migration
/// organically, so migration is forced — same shortcut the existing
/// `AttributeListMigrationTests` use).
final class IndexAllocationGrowthTests: XCTestCase {

    // MARK: helpers (copied from AttributeListMigrationTests — private there)

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here.deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path)
    }

    private func orphans(in volume: Volume, maxRN: UInt64 = 4096) async throws -> Set<UInt64> {
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

    private func findExtensionRecord(for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 4096) async throws -> UInt64? {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.baseFileReference != 0 && (rec.baseFileReference & mask) == baseRN {
                return rn
            }
        }
        return nil
    }

    private func countExtensionRecords(for baseRN: UInt64, in volume: Volume, maxRN: UInt64 = 4096) async throws -> Int {
        let mft = await volume.mft()
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        var n = 0
        for rn: UInt64 in 0..<maxRN {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.isInUse && rec.baseFileReference != 0 && (rec.baseFileReference & mask) == baseRN {
                n += 1
            }
        }
        return n
    }

    private func ensureNonResidentIndexAllocation(
        volume: Volume, parentRN: UInt64, prefix: String, maxAttempts: Int = 200
    ) async throws -> [String] {
        var inserted: [String] = []
        for i in 0..<maxAttempts {
            let name = String(format: "\(prefix)-%05d.txt", i)
            do { _ = try await volume.createFile(named: name, inDirectory: parentRN); inserted.append(name) }
            catch NTFSError.unsupportedFeature { break } catch NTFSError.outOfSpace { break }
            if (i % 16) == 15 {
                let mft = await volume.mft()
                let rec = try await mft.record(at: parentRN)
                let attrs = try rec.attributes()
                let hasNonResIA = attrs.contains { a in
                    if a.type == .indexAllocation, a.nameOrEmpty == "$I30", case .nonResident = a.value { return true }
                    return false
                }
                if hasNonResIA { break }
            }
        }
        return inserted
    }

    /// Insert `target` files post-migration, growing `$MFT.$DATA` on demand so
    /// the MFT-slot ceiling isn't mistaken for a structural index ceiling.
    /// Stops early on `outOfSpace`. Returns the inserted names and (if
    /// stopped early) the captured first failure description.
    private func insertGrowingMFT(
        volume: Volume, parentRN: UInt64, startIdx: Int, target: Int, prefix: String
    ) async throws -> (inserted: [String], firstFailure: String?) {
        var inserted: [String] = []
        var firstFailure: String? = nil
        outer: for i in startIdx..<(startIdx + target) {
            let name = String(format: "\(prefix)-%05d.txt", i)
            for attempt in 0..<2 {
                do { _ = try await volume.createFile(named: name, inDirectory: parentRN); inserted.append(name); continue outer }
                catch NTFSError.outOfSpace { firstFailure = "outOfSpace"; break outer }
                catch let e {
                    let s = "\(e)"
                    if attempt == 0, s.contains("$MFT.$DATA") || s.contains("auto-grow") {
                        try? await volume.growMFTDataByClusters(128); continue
                    }
                    firstFailure = "\(type(of: e)): \(e)"; break outer
                }
            }
        }
        return (inserted, firstFailure)
    }

    // MARK: AC-1 + AC-6 — post-migration growth lifts the ceiling, audit-clean
    //
    // Without the fix this test FAILS within ~16 post-migration inserts on
    // main with `corruptOnDisk: target type 0xA0 name '$I30' not found`. With
    // the routing fix it inserts 1,500+ cleanly, exercising the cascade →
    // root-overflow → height-grow path that previously orphaned a 36-entry
    // subtree (caught by the pre-existing `splitLeafAndPromote` guard).
    func testPostMigrationGrowthLiftsCeilingAndIsAuditClean() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        for _ in 0..<8 { try? await volume.growMFTDataByClusters(64) }

        let preMigration = try await ensureNonResidentIndexAllocation(
            volume: volume, parentRN: 5, prefix: "pm")
        XCTAssertGreaterThan(preMigration.count, 10, "expected LARGE_INDEX before migration; got \(preMigration.count)")
        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (synthetic test invocation, type 0xa0)")
        let extRNAfterMigration = try await findExtensionRecord(for: 5, in: volume)
        XCTAssertNotNil(extRNAfterMigration, "migration must create exactly one extension record")
        let extCountAfterMigration = try await countExtensionRecords(for: 5, in: volume)
        XCTAssertEqual(extCountAfterMigration, 1, "exactly one extension record post-migration")

        // 1,500 well exceeds the cascade→height-grow trigger (~1,000 on this
        // fixture). On main this throws within ~16; with the fix it succeeds.
        let post = try await insertGrowingMFT(
            volume: volume, parentRN: 5, startIdx: preMigration.count, target: 1500, prefix: "pm")
        XCTAssertNil(post.firstFailure,
            "post-migration growth must NOT throw a structural error; got \(post.firstFailure ?? "?")")
        XCTAssertEqual(post.inserted.count, 1500,
            "expected 1500 clean post-migration inserts; got \(post.inserted.count)")

        // No new extension records were allocated for the directory by the
        // growth (the v0.5 fix is in-place rewrites of the SAME extension).
        let extCountAfterGrowth = try await countExtensionRecords(for: 5, in: volume)
        XCTAssertEqual(extCountAfterGrowth, 1,
            "no extra extension records should be allocated by post-migration growth; got \(extCountAfterGrowth)")

        // Enumeration must surface every inserted name (none orphaned).
        let allNames = Set(preMigration + post.inserted)
        let enumerated = Set(try await volume.enumerate(directory: 5).map { $0.name })
        XCTAssertTrue(allNames.isSubset(of: enumerated),
            "post-growth enumeration is missing \(allNames.subtracting(enumerated).count) names")

        // Reopen from disk — durable shape.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let reopened = Set(try await reopen.enumerate(directory: 5).map { $0.name })
        XCTAssertTrue(allNames.isSubset(of: reopened),
            "reopen lost \(allNames.subtracting(reopened).count) names")

        // Orphan walk: no leaked MFT slots.
        let leaked = try await orphans(in: reopen)
        XCTAssertTrue(leaked.isEmpty,
            "post-growth volume must be orphan-free; got \(leaked.count): \(leaked.sorted().prefix(10))")

        // Runlist ↔ $Bitmap audit (the `verify --deep` discipline).
        let sweep = try await reopen.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(sweep.isClean,
            "post-growth audit must be clean; got \(sweep.perRecordAnomalies.count) anomalies")
    }

    // MARK: AC-4 — independent spec-conformance of the post-growth on-disk shape
    //
    // Hand-decode the produced bytes without using NTFSCore's high-level
    // decoders, mirroring the PR #26 pattern (MigratedDataSpecConformance).
    // Asserts the $ATTRIBUTE_LIST is well-formed and sorted, the migrated
    // $INDEX_ALLOCATION:$I30 entry points at the extension record, the
    // extension record's baseFileReference packs correctly, and the
    // extension's rewritten $INDEX_ALLOCATION attribute header is well-formed
    // with a runlist that terminates with 0x00 within its recorded length.
    func testPostMigrationGrowthLayoutIsSpecConformant() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        for _ in 0..<4 { try? await volume.growMFTDataByClusters(64) }

        let pre = try await ensureNonResidentIndexAllocation(
            volume: volume, parentRN: 5, prefix: "sp")
        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (synthetic test invocation, type 0xa0)")
        // Drive enough post-migration growth that the extension's
        // $INDEX_ALLOCATION attribute has actually been rewritten in place
        // (not just the immediate post-migration shape).
        _ = try await insertGrowingMFT(
            volume: volume, parentRN: 5, startIdx: pre.count, target: 200, prefix: "sp")

        let mft = await volume.mft()
        let base = try await mft.record(at: 5)
        let baseSeq = base.sequenceNumber
        guard let extRN = try await findExtensionRecord(for: 5, in: volume) else {
            return XCTFail("no extension record found")
        }
        let extRec = try await mft.record(at: extRN)

        // Independent USA fix-up + raw record reads off the device.
        let raw = try await readRecordRaw(recordNumber: 5, device: device, volume: volume)
        let extRaw = try await readRecordRaw(recordNumber: extRN, device: device, volume: volume)

        // baseFileReference layout: low-48 = recnum, high-16 = sequence,
        // little-endian. (Same byte-shape check the existing migration
        // round-trip uses; reiterated here against the GROWN extension.)
        let extBaseRef = u64(extRaw, 32) // bytes 32..40 of an MFT record
        XCTAssertEqual(extBaseRef & 0x0000_FFFF_FFFF_FFFF, 5,
            "extension baseFileReference recnum field must equal base RN 5")
        XCTAssertEqual(UInt16((extBaseRef >> 48) & 0xFFFF), baseSeq,
            "extension baseFileReference sequence field must equal base sequence")
        XCTAssertEqual(extBaseRef, extRec.baseFileReference,
            "raw baseFileReference must equal MFTRecord.baseFileReference")

        // Walk base record's attributes BY HAND. Confirm $ATTRIBUTE_LIST
        // (0x20) is present and $INDEX_ALLOCATION:$I30 (0xA0) is NOT in the
        // base.
        let baseAttrs = try walkAttributes(raw)
        XCTAssertTrue(baseAttrs.contains { $0.type == 0x20 },
            "base must hold $ATTRIBUTE_LIST after migration")
        XCTAssertFalse(baseAttrs.contains { $0.type == 0xA0 },
            "base must NOT hold $INDEX_ALLOCATION after migration")

        // Hand-decode the resident $ATTRIBUTE_LIST body and validate it.
        let alAttr = baseAttrs.first { $0.type == 0x20 }!
        // Resident header: bodyLength @ +16, bodyOffset @ +20.
        let bodyLen = Int(u32(raw, alAttr.start + 16))
        let bodyOff = Int(u16(raw, alAttr.start + 20))
        let bodyBytes = Array(raw[(alAttr.start + bodyOff)..<(alAttr.start + bodyOff + bodyLen)])
        let entries = try decodeAttributeList(bodyBytes, bodyLen: bodyLen)
        XCTAssertGreaterThan(entries.count, 1, "$ATTRIBUTE_LIST should describe several attributes")

        // Canonical sort: (type, name, lowestVCN) ascending. Names are
        // UTF-16 LE in the entry tail.
        for i in 1..<entries.count {
            let a = entries[i - 1], b = entries[i]
            if a.type != b.type {
                XCTAssertLessThan(a.type, b.type, "AL entries not sorted by type at index \(i)")
                continue
            }
            // Same type: name (UTF-16) then lowestVCN.
            let an = utf16Slice(bodyBytes, offsetInBody: bytePosOf(entry: i - 1, in: entries) + a.nameOffset, codeUnits: a.nameLength)
            let bn = utf16Slice(bodyBytes, offsetInBody: bytePosOf(entry: i, in: entries) + b.nameOffset, codeUnits: b.nameLength)
            if an != bn {
                XCTAssertTrue(lexLessUTF16(an, bn), "AL entries at index \(i): name not sorted (\(an) vs \(bn))")
                continue
            }
            XCTAssertLessThanOrEqual(a.startingVCN, b.startingVCN,
                "AL entries at index \(i): same (type,name) but lowestVCN out of order")
        }

        // The migrant ($INDEX_ALLOCATION:$I30 — 0xA0, name "$I30") must point
        // at the extension record; every other entry must point at base 5.
        var sawMigrant = false
        for (i, e) in entries.enumerated() {
            if e.type == 0xA0 {
                let name = utf16Slice(bodyBytes, offsetInBody: bytePosOf(entry: i, in: entries) + e.nameOffset, codeUnits: e.nameLength)
                if name == [0x24, 0x49, 0x33, 0x30] /* "$I30" UTF-16 LE: $,I,3,0 */ {
                    sawMigrant = true
                    XCTAssertEqual(e.recordNumber, extRN,
                        "migrant $INDEX_ALLOCATION:$I30 entry must point at the extension record")
                    XCTAssertEqual(e.sequence, extRec.sequenceNumber,
                        "migrant entry's sequence must match extension record's sequence")
                }
            } else {
                XCTAssertEqual(e.recordNumber, 5,
                    "non-migrant $ATTRIBUTE_LIST entry (type 0x\(String(e.type, radix: 16))) must reference base 5")
            }
        }
        XCTAssertTrue(sawMigrant, "no $INDEX_ALLOCATION:$I30 entry found in $ATTRIBUTE_LIST")

        // Walk the EXTENSION record's attributes by hand. It must hold the
        // $INDEX_ALLOCATION attribute, non-resident, with a well-formed
        // runlist that terminates with 0x00 within its recorded length.
        let extAttrs = try walkAttributes(extRaw)
        guard let iaInExt = extAttrs.first(where: { $0.type == 0xA0 && $0.nonResident }) else {
            return XCTFail("extension record must hold non-resident $INDEX_ALLOCATION (0xA0)")
        }
        // Non-resident header: dataRunsOffset @ +32 (u16), allocatedSize @ +40 (u64).
        let rlOffset = Int(u16(extRaw, iaInExt.start + 32))
        let attrLen = iaInExt.length
        XCTAssertGreaterThan(rlOffset, 0, "non-resident dataRunsOffset must be > 0")
        XCTAssertLessThan(rlOffset, attrLen, "dataRunsOffset must be within the attribute")
        let rlWindow = attrLen - rlOffset
        let rl = Array(extRaw[(iaInExt.start + rlOffset)..<(iaInExt.start + attrLen)])
        let runs = try specDecode(rl, boundary: rlWindow)
        XCTAssertGreaterThan(runs.count, 0, "post-growth runlist must contain >= 1 run")
        // None of the decoded runs should be sparse for an index allocation.
        for (i, r) in runs.enumerated() {
            XCTAssertNotNil(r.lcn, "run \(i) of $INDEX_ALLOCATION must not be sparse")
        }
    }

    // MARK: AC-6 — transactional discipline on cluster exhaustion
    //
    // Drive post-migration growth until outOfSpace, then assert: no orphan
    // extension records, no leaked clusters (audit clean), and the directory
    // is enumerable end-to-end. Catches transactional bugs in the new
    // routing-fix path even though we can't easily hook a synthetic failure.
    func testPostMigrationGrowthToExhaustionLeavesNoLeak() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        for _ in 0..<40 { try? await volume.growMFTDataByClusters(64) }

        let pre = try await ensureNonResidentIndexAllocation(
            volume: volume, parentRN: 5, prefix: "ex")
        try await volume.migrateIndexAllocationOnOverflow(
            baseRecordNumber: 5,
            overflowDescription: "would overflow record (synthetic test invocation, type 0xa0)")

        // Drive growth to exhaustion (target much larger than fixture capacity
        // so the loop only stops on a real ceiling). Both raw `outOfSpace` and
        // the downstream `$MFT.$DATA` "can't auto-grow" are legitimate
        // exhaustion modes on small.img (growing $MFT itself needs free
        // clusters). What MUST NOT happen is a structural index error
        // (target-not-found, would-overflow record 0xA0, post-split state
        // mismatch) — those would mean the routing/corruption fix regressed.
        let post = try await insertGrowingMFT(
            volume: volume, parentRN: 5, startIdx: pre.count, target: 10_000, prefix: "ex")
        if let f = post.firstFailure {
            let isExhaustion = f == "outOfSpace"
                || f.contains("$MFT.$DATA") || f.contains("auto-grow")
            XCTAssertTrue(isExhaustion,
                "exhaustion path must end at a cluster/slot exhaustion, not a structural error; got \(f)")
        }

        // The directory must remain enumerable end-to-end (no half-committed
        // splits leaving the tree inconsistent at the boundary).
        let names = Set(try await volume.enumerate(directory: 5).map { $0.name })
        let inserted = Set(pre + post.inserted)
        XCTAssertTrue(inserted.isSubset(of: names),
            "exhaustion left \(inserted.subtracting(names).count) inserted names unreadable")

        // Reopen + final audit: this is the strict no-leak gate.
        let reopen = try await Volume(device: FileHandleBlockDevice(openingFileAt: path))
        let leaked = try await orphans(in: reopen)
        XCTAssertTrue(leaked.isEmpty,
            "post-exhaustion volume must be orphan-free; got \(leaked.count): \(leaked.sorted().prefix(10))")
        let sweep = try await reopen.auditAllDataRunlistsAgainstBitmap()
        XCTAssertTrue(sweep.isClean,
            "post-exhaustion audit must be clean; got \(sweep.perRecordAnomalies.count) anomalies")
    }

    // MARK: - Independent-decoder helpers (mirrored from MigratedDataSpecConformanceTests)

    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * i) }; return v
    }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) }; return v
    }

    private struct IndepError: Error, CustomStringConvertible {
        let m: String; init(_ m: String) { self.m = m }; var description: String { m }
    }

    private func independentFixup(_ raw: [UInt8], sectorSize: Int) throws -> [UInt8] {
        let usaOffset = Int(u16(raw, 4))
        let usaCount  = Int(u16(raw, 6))
        let fixups = raw.count / sectorSize
        guard usaCount == fixups + 1 else { throw IndepError("USA count \(usaCount) != sectors+1") }
        guard usaOffset + usaCount * 2 <= raw.count else { throw IndepError("USA range out of bounds") }
        let sentinel = u16(raw, usaOffset)
        var out = raw
        for i in 0..<fixups {
            let tail = (i + 1) * sectorSize - 2
            let onDisk = u16(raw, tail)
            guard onDisk == sentinel else { throw IndepError("USA sentinel mismatch sector \(i)") }
            let usaPos = usaOffset + 2 * (i + 1)
            out[tail] = raw[usaPos]; out[tail + 1] = raw[usaPos + 1]
        }
        return out
    }

    private func readRecordRaw(recordNumber: UInt64, device: any BlockDevice, volume: Volume) async throws -> [UInt8] {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        let byteOffset: UInt64
        if let extents = await volume.mftDataExtents() {
            let clusterBytes = UInt64(volume.bytesPerCluster)
            let recordsPerCluster = max(UInt64(1), clusterBytes / recordSize)
            var resolved: UInt64? = nil
            var seen: UInt64 = 0
            for e in extents {
                let recordsInExtent = e.clusterCount * recordsPerCluster
                if recordNumber < seen + recordsInExtent, let lcn = e.startLCN {
                    let recordInExtent = recordNumber - seen
                    resolved = lcn * clusterBytes + recordInExtent * recordSize
                    break
                }
                seen += recordsInExtent
            }
            guard let off = resolved else { throw IndepError("record \(recordNumber) not within $MFT extents") }
            byteOffset = off
        } else {
            byteOffset = volume.mftByteOffset + recordNumber * recordSize
        }
        let raw = try await device.read(offset: byteOffset, length: Int(recordSize))
        return try independentFixup([UInt8](raw), sectorSize: sectorSize)
    }

    private struct RawAttr {
        let start: Int; let length: Int; let type: UInt32
        let nonResident: Bool; let nameLength: Int; let attributeID: UInt16
    }
    private func walkAttributes(_ rec: [UInt8]) throws -> [RawAttr] {
        let firstAttr = Int(u16(rec, 20))
        let usedSize = Int(u32(rec, 24))
        var out: [RawAttr] = []; var cursor = firstAttr
        while cursor + 4 <= usedSize {
            let type = u32(rec, cursor)
            if type == 0xFFFF_FFFF { break }
            guard cursor + 16 <= usedSize else { break }
            let length = Int(u32(rec, cursor + 4))
            guard length >= 16, cursor + length <= rec.count else { break }
            let nonResident = rec[cursor + 8] != 0
            let nameLength = Int(rec[cursor + 9])
            let attrID = u16(rec, cursor + 14)
            out.append(RawAttr(start: cursor, length: length, type: type,
                nonResident: nonResident, nameLength: nameLength, attributeID: attrID))
            cursor += length
        }
        return out
    }

    private struct AListEntry {
        let type: UInt32; let recordLength: Int; let nameLength: Int
        let nameOffset: Int; let startingVCN: UInt64; let mftReference: UInt64; let attributeID: UInt16
        var recordNumber: UInt64 { mftReference & 0x0000_FFFF_FFFF_FFFF }
        var sequence: UInt16 { UInt16((mftReference >> 48) & 0xFFFF) }
    }
    private func decodeAttributeList(_ body: [UInt8], bodyLen: Int) throws -> [AListEntry] {
        var entries: [AListEntry] = []; var pos = 0
        let limit = min(bodyLen, body.count)
        while pos + 26 <= limit {
            let type = u32(body, pos + 0)
            let recLen = Int(u16(body, pos + 4))
            if type == 0xFFFF_FFFF || recLen == 0 { break }
            guard recLen >= 26, recLen % 8 == 0, pos + recLen <= limit else {
                throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): bad recordLength \(recLen)")
            }
            let nameLen = Int(body[pos + 6])
            let nameOff = Int(body[pos + 7])
            let vcn = u64(body, pos + 8)
            let ref = u64(body, pos + 16)
            let id = u16(body, pos + 24)
            entries.append(AListEntry(type: type, recordLength: recLen, nameLength: nameLen,
                nameOffset: nameOff, startingVCN: vcn, mftReference: ref, attributeID: id))
            pos += recLen
        }
        return entries
    }

    /// Byte position of entry `i`'s start within the $ATTRIBUTE_LIST body.
    private func bytePosOf(entry i: Int, in entries: [AListEntry]) -> Int {
        var p = 0; for k in 0..<i { p += entries[k].recordLength }; return p
    }

    /// Read `codeUnits` UTF-16 LE code points starting at `offsetInBody`.
    private func utf16Slice(_ body: [UInt8], offsetInBody: Int, codeUnits: Int) -> [UInt16] {
        var out: [UInt16] = []; out.reserveCapacity(codeUnits)
        for i in 0..<codeUnits {
            let p = offsetInBody + i * 2
            out.append(UInt16(body[p]) | (UInt16(body[p + 1]) << 8))
        }
        return out
    }

    private func lexLessUTF16(_ a: [UInt16], _ b: [UInt16]) -> Bool {
        let n = min(a.count, b.count)
        for i in 0..<n { if a[i] != b[i] { return a[i] < b[i] } }
        return a.count < b.count
    }

    private struct SpecRun: Equatable { let lcn: Int64?; let length: UInt64 }
    private enum SpecDecodeError: Error {
        case truncated, missingTerminator, negativeLCN
    }
    private func specDecode(_ data: [UInt8], boundary: Int) throws -> [SpecRun] {
        let limit = min(boundary, data.count)
        var runs: [SpecRun] = []; var cursor = 0; var prev: Int64 = 0
        while true {
            guard cursor < limit else { throw SpecDecodeError.missingTerminator }
            let header = data[cursor]; cursor += 1
            if header == 0 { return runs }
            let L = Int(header & 0x0F)
            let V = Int((header & 0xF0) >> 4)
            guard cursor + L + V <= limit else { throw SpecDecodeError.truncated }
            var length: UInt64 = 0
            for i in 0..<L { length |= UInt64(data[cursor + i]) << (8 * i) }
            cursor += L
            if V == 0 { runs.append(SpecRun(lcn: nil, length: length)); continue }
            var u: UInt64 = 0
            for i in 0..<V { u |= UInt64(data[cursor + i]) << (8 * i) }
            if V < 8, (u & (UInt64(1) << (8 * V - 1))) != 0 { u |= UInt64.max << (8 * V) }
            let delta = Int64(bitPattern: u); cursor += V
            let lcn = prev &+ delta
            guard lcn >= 0 else { throw SpecDecodeError.negativeLCN }
            runs.append(SpecRun(lcn: lcn, length: length)); prev = lcn
        }
    }
}
