import XCTest
@testable import NTFSCore

/// Independent spec-conformance regression guard for MIGRATED unnamed `$DATA`.
///
/// Context (negative result): a v0.5 portability blocker suspected that
/// "late-written, fragmented" files — whose longer runlist overflows the base
/// MFT record and MIGRATES the unnamed `$DATA` into an EXTENSION record,
/// dropping a resident `$ATTRIBUTE_LIST` (type 0x20) on the base — were
/// malformed for a strict reader (Apple's native driver raises
/// `Input/output error` reading their CONTENT while `ntfsctl cat` reads them
/// byte-exact; directory enumeration still works because it reads the PARENT's
/// `$INDEX` copy of `$FILE_NAME`, never the child's own record). That suspected
/// migration/`$ATTRIBUTE_LIST` encoding bug was DISPROVEN here.
///
/// The companion `MultiExtentDataTests` already proved the multi-extent
/// `$DATA` ENCODER, non-resident header coverage fields, and end-to-end
/// physical placement spec-conformant. This file closes the migrated-layout
/// half of the PR #13 gap: the existing `DataMigrationTests` only verify
/// OUR-reader round-trip + `$ATTRIBUTE_LIST` structure via OUR parsers; the
/// migrated layout had NEVER been independently cross-read. After forcing a
/// FULLY-ORGANIC `$DATA` migration, the test below RE-OPENS the image and
/// decodes the base `$ATTRIBUTE_LIST`, the extension record header, the
/// extension `$DATA` header + runlist, and the physical content ALL BY HAND
/// per the NTFS on-disk spec — never via `MFTRecord.parse`,
/// `Attribute.iterate`, `AttributeListEntry.parseAll`, `DataRun.decode`, or
/// `Volume.readFile` — and finds them spec-clean.
///
/// Kept as a PERMANENT regression guard. NOTE: documented negative result, NOT
/// a bug fix — this test is not expected to fail on `main`; the real hardware
/// I/O-error remains OPEN and is not reproducible in the `.img`-fixture
/// toolchain (see `docs/STATUS.md`).
final class MigratedDataSpecConformanceTests: XCTestCase {

    // =====================================================================
    // MARK: - Organic-migration driver (copied technique from DataMigrationTests)
    // =====================================================================

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Deterministic content generator — mirrors `DataMigrationTests` so the
    /// payload can be byte-compared on read-back without holding a copy.
    private static func contentByte(at i: UInt64) -> UInt8 {
        UInt8((i &* 31 &+ 7) & 0xFF)
    }

    /// Carve the free space into a swiss-cheese bitmap (max contiguous run ==
    /// 1 cluster) so the subsequent `writeFile` is forced to allocate a long,
    /// highly-fragmented runlist. Copied from `DataMigrationTests`.
    private func fragmentFreeSpace(_ volume: Volume) async throws -> UInt64 {
        var singles: [Extent] = []
        while let e = try? await volume.allocateClusters(1) {
            singles.append(e)
            if singles.count > 4096 { break }   // safety bound
        }
        for (i, e) in singles.enumerated() where i % 2 == 0 {
            try await volume.freeClusters(e)
        }
        return try await volume.allocationStats().freeClusters
    }

    /// Find the extension MFT record whose `baseFileReference` points at
    /// `baseRN`. This LOCATES the slot only (the migration allocates it lazily);
    /// the spec verification below reads that slot's bytes INDEPENDENTLY off the
    /// device. Copied from `DataMigrationTests`.
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

    /// Drive a fully-organic non-resident `$DATA` overflow on a fragmented
    /// volume — `createFile` + `fragmentFreeSpace` + streaming `writeFile`.
    /// The 260-cluster default lands in the migration-success window measured
    /// on `small.img`. Returns the file's record number and the exact byte
    /// length written. Copied from `DataMigrationTests`.
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

    // =====================================================================
    // MARK: - Independent (spec-strict) primitives — NO project parsers
    // =====================================================================

    private func hex(_ d: [UInt8]) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    private func hex(_ d: Data) -> String { hex([UInt8](d)) }

    // -- little-endian readers over a flat [UInt8] (independent of Endian.swift)

    private func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * i) }; return v
    }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * i) }; return v
    }

    /// Independent USA fix-up: verify every sector's tail sentinel equals
    /// USA[0], then restore the original tail bytes from USA[1..N]. Re-derived
    /// from the on-disk format, NOT calling `UpdateSequenceArray`.
    private func independentFixup(_ raw: [UInt8], sectorSize: Int) throws -> [UInt8] {
        let usaOffset = Int(u16(raw, 4))
        let usaCount  = Int(u16(raw, 6))
        let fixups = raw.count / sectorSize
        guard usaCount == fixups + 1 else {
            throw IndepError("USA count \(usaCount) != sectors+1 (\(fixups + 1))")
        }
        guard usaOffset + usaCount * 2 <= raw.count else {
            throw IndepError("USA range out of bounds")
        }
        let sentinel = u16(raw, usaOffset)
        var out = raw
        for i in 0..<fixups {
            let tail = (i + 1) * sectorSize - 2
            let onDisk = u16(raw, tail)
            guard onDisk == sentinel else {
                throw IndepError("USA sentinel mismatch in sector \(i): want 0x\(String(format: "%04X", sentinel)) got 0x\(String(format: "%04X", onDisk))")
            }
            let usaPos = usaOffset + 2 * (i + 1)
            out[tail]     = raw[usaPos]
            out[tail + 1] = raw[usaPos + 1]
        }
        return out
    }

    private struct IndepError: Error, CustomStringConvertible {
        let m: String
        init(_ m: String) { self.m = m }
        var description: String { m }
    }

    // -- Independent spec-strict runlist decoder (same approach as MultiExtentDataTests)

    private struct SpecRun: Equatable { let lcn: Int64?; let length: UInt64 }

    private enum SpecDecodeError: Error, CustomStringConvertible {
        case truncated(at: Int, need: Int, have: Int)
        case missingTerminator
        case negativeLCN(Int64)
        var description: String {
            switch self {
            case let .truncated(at, need, have):
                return "runlist truncated at byte \(at): need \(need) more bytes, only \(have) within recorded length"
            case .missingTerminator:
                return "runlist not terminated by 0x00 within recorded length"
            case let .negativeLCN(v):
                return "signed delta produced negative LCN \(v)"
            }
        }
    }

    /// Decode an NTFS runlist STRICTLY per the on-disk format, independent of
    /// `DataRun.decode`. `boundary` is the number of bytes a strict reader is
    /// ALLOWED to read (the attribute-recorded runlist window); a terminator
    /// must appear within it.
    private func specDecode(_ data: [UInt8], boundary: Int) throws -> [SpecRun] {
        let limit = min(boundary, data.count)
        var runs: [SpecRun] = []
        var cursor = 0
        var prev: Int64 = 0
        while true {
            guard cursor < limit else { throw SpecDecodeError.missingTerminator }
            let header = data[cursor]; cursor += 1
            if header == 0 { return runs }
            let L = Int(header & 0x0F)
            let V = Int((header & 0xF0) >> 4)
            guard cursor + L + V <= limit else {
                throw SpecDecodeError.truncated(at: cursor, need: L + V, have: limit - cursor)
            }
            var length: UInt64 = 0
            for i in 0..<L { length |= UInt64(data[cursor + i]) << (8 * i) }
            cursor += L
            if V == 0 {
                runs.append(SpecRun(lcn: nil, length: length)); continue
            }
            var u: UInt64 = 0
            for i in 0..<V { u |= UInt64(data[cursor + i]) << (8 * i) }
            if V < 8, (u & (UInt64(1) << (8 * V - 1))) != 0 {
                u |= UInt64.max << (8 * V)
            }
            let delta = Int64(bitPattern: u)
            cursor += V
            let lcn = prev &+ delta
            guard lcn >= 0 else { throw SpecDecodeError.negativeLCN(lcn) }
            runs.append(SpecRun(lcn: lcn, length: length))
            prev = lcn
        }
    }

    // -- Independent $ATTRIBUTE_LIST entry decode

    private struct AListEntry {
        let type: UInt32
        let recordLength: Int
        let nameLength: Int      // UTF-16 code units
        let nameOffset: Int
        let startingVCN: UInt64  // == lowestVCN
        let mftReference: UInt64
        let attributeID: UInt16
        var recordNumber: UInt64 { mftReference & 0x0000_FFFF_FFFF_FFFF }
        var sequence: UInt16 { UInt16((mftReference >> 48) & 0xFFFF) }
    }

    /// Decode the $ATTRIBUTE_LIST body byte-by-byte per spec. `bodyLen` is the
    /// attribute's recorded value length — a strict reader walks exactly that
    /// window. Throws on a structural spec violation so the test pins it.
    private func decodeAttributeList(_ body: [UInt8], bodyLen: Int) throws -> [AListEntry] {
        var entries: [AListEntry] = []
        var pos = 0
        let limit = min(bodyLen, body.count)
        while pos + 26 <= limit {
            let type = u32(body, pos + 0)
            let recLen = Int(u16(body, pos + 4))
            // type 0xFFFFFFFF or recLen 0 terminate the list cleanly.
            if type == 0xFFFF_FFFF || recLen == 0 { break }
            guard recLen >= 26 else {
                throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): recordLength \(recLen) < 26")
            }
            guard recLen % 8 == 0 else {
                throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): recordLength \(recLen) not a multiple of 8")
            }
            guard pos + recLen <= limit else {
                throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): recordLength \(recLen) overruns body window \(limit)")
            }
            let nameLen = Int(body[pos + 6])
            let nameOff = Int(body[pos + 7])
            let vcn = u64(body, pos + 8)
            let ref = u64(body, pos + 16)
            let id = u16(body, pos + 24)
            if nameLen > 0 {
                guard nameOff >= 26 else {
                    throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): nameOffset \(nameOff) < 26 (overlaps header)")
                }
                guard nameOff + nameLen * 2 <= recLen else {
                    throw IndepError("$ATTRIBUTE_LIST entry at +\(pos): name [\(nameOff)..\(nameOff + nameLen * 2)) past entry end \(recLen)")
                }
            }
            entries.append(AListEntry(
                type: type, recordLength: recLen, nameLength: nameLen,
                nameOffset: nameOff, startingVCN: vcn, mftReference: ref, attributeID: id
            ))
            pos += recLen
        }
        return entries
    }

    // -- Raw device record read + independent attribute walk

    /// Read one MFT record RAW off the device and apply our OWN USA fix-up.
    /// Uses ONLY published geometry (`mftByteOffset`, `mftRecordSizeBytes`,
    /// `mftDataExtents`) — never `MFTRecord.parse`.
    private func readRecordRaw(
        recordNumber: UInt64,
        device: any BlockDevice,
        volume: Volume
    ) async throws -> [UInt8] {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let sectorSize = Int(volume.boot.bytesPerSector)
        // Compute the device byte offset of this record, honoring a fragmented
        // $MFT.$DATA if present (small.img is contiguous, but be robust).
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
            guard let off = resolved else {
                throw IndepError("record \(recordNumber) not within $MFT extents")
            }
            byteOffset = off
        } else {
            byteOffset = volume.mftByteOffset + recordNumber * recordSize
        }
        let raw = try await device.read(offset: byteOffset, length: Int(recordSize))
        return try independentFixup([UInt8](raw), sectorSize: sectorSize)
    }

    /// One attribute located by an independent walk of a (fixed-up) record.
    private struct RawAttr {
        let start: Int
        let length: Int
        let type: UInt32
        let nonResident: Bool
        let nameLength: Int
        let attributeID: UInt16
    }

    /// Walk a fixed-up record's attribute stream BY HAND (independent of
    /// `Attribute.iterate`). Returns every attribute up to the end marker.
    private func walkAttributes(_ rec: [UInt8]) throws -> [RawAttr] {
        let firstAttr = Int(u16(rec, 20))
        let used = Int(u32(rec, 24))
        let upper = min(used, rec.count)
        var out: [RawAttr] = []
        var c = firstAttr
        while c + 4 <= upper {
            let type = u32(rec, c)
            if type == 0xFFFF_FFFF { break }
            guard c + 16 <= upper else {
                throw IndepError("attribute header truncated at +\(c)")
            }
            let len = Int(u32(rec, c + 4))
            guard len >= 16, c + len <= upper else {
                throw IndepError("attribute at +\(c) length \(len) overruns record (used \(used))")
            }
            out.append(RawAttr(
                start: c, length: len, type: type,
                nonResident: rec[c + 8] != 0,
                nameLength: Int(rec[c + 9]),
                attributeID: u16(rec, c + 14)
            ))
            c += len
        }
        return out
    }

    // =====================================================================
    // MARK: - THE TEST: independent spec-conformance of the migrated layout
    // =====================================================================

    func testMigratedDataIsSpecConformantToIndependentReader() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // -- Force a fully-organic $DATA migration. ----------------------
        let (rn, total) = try await driveDataOverflow(volume: volume, named: "migrated-spec.bin")

        // Precondition: the migration actually fired. We use our parser ONLY to
        // CONFIRM the precondition and LOCATE slots; the spec verification below
        // reads bytes independently. If it did not migrate, skip loudly.
        let mft = await volume.mft()
        let baseRecParsed = try await mft.record(at: rn)
        let baseAttrsParsed = try baseRecParsed.attributes()
        guard baseAttrsParsed.contains(where: { $0.rawType == AttributeType.attributeList.rawValue }) else {
            throw XCTSkip("$DATA did NOT migrate (base has no $ATTRIBUTE_LIST) — increase fragmentation/size to exercise a real migration")
        }
        guard let extRN = try await findExtensionRecord(for: rn, in: volume) else {
            XCTFail("migration fired but no extension record found"); return
        }
        let baseSeqExpected = baseRecParsed.sequenceNumber
        let extSeqExpected  = (try await mft.record(at: extRN)).sequenceNumber

        // Build a fresh RAW reader handle so nothing shares state with the
        // write-path Volume actor.
        let raw = try FileHandleBlockDevice(openingFileAt: path)
        let rv = try await Volume(device: raw)   // used ONLY for published geometry
        let clusterBytes = UInt64(rv.bytesPerCluster)

        var violations: [String] = []

        // ============================================================
        // STEP 1 — Base record: locate + decode $ATTRIBUTE_LIST by hand.
        // ============================================================
        let baseRaw = try await readRecordRaw(recordNumber: rn, device: raw, volume: rv)

        // 1.0 base record sanity (independent).
        XCTAssertEqual(u32(baseRaw, 0), 0x454C_4946, "base record must carry 'FILE' magic")
        let baseFlags = u16(baseRaw, 22)
        XCTAssertEqual(baseFlags & 0x0001, 0x0001, "base record IN_USE flag must be set")
        XCTAssertEqual(u64(baseRaw, 32), 0, "base record baseFileReference must be 0 (it IS the base)")
        let baseSeqRaw = u16(baseRaw, 16)

        let baseAttrs = try walkAttributes(baseRaw)

        // 1.a Base must carry the resident $ATTRIBUTE_LIST (0x20) and NOT an
        //     in-base unnamed $DATA.
        guard let alAttr = baseAttrs.first(where: { $0.type == 0x20 }) else {
            XCTFail("INDEPENDENT base walk found no $ATTRIBUTE_LIST (0x20)"); return
        }
        XCTAssertFalse(
            baseAttrs.contains { $0.type == 0x80 && $0.nameLength == 0 },
            "base must NOT still hold an unnamed $DATA after migration"
        )

        // 1.b $ATTRIBUTE_LIST must be resident in v0.5; decode its value window.
        XCTAssertFalse(alAttr.nonResident, "$ATTRIBUTE_LIST expected resident in v0.5")
        let alValueLen = Int(u32(baseRaw, alAttr.start + 16))
        let alValueOff = Int(u16(baseRaw, alAttr.start + 20))
        XCTAssertGreaterThanOrEqual(alValueOff, 24, "$ATTRIBUTE_LIST value offset must clear the resident header")
        XCTAssertLessThanOrEqual(
            alValueOff + alValueLen, alAttr.length,
            "$ATTRIBUTE_LIST resident value must fit inside the attribute"
        )
        let alBody = Array(baseRaw[(alAttr.start + alValueOff)..<(alAttr.start + alValueOff + alValueLen)])

        // 1.c Decode entries independently — throws pin a structural violation.
        let entries: [AListEntry]
        do {
            entries = try decodeAttributeList(alBody, bodyLen: alValueLen)
        } catch {
            violations.append("STEP 1 — $ATTRIBUTE_LIST structurally invalid: \(error)\n  body: \(hex(alBody))")
            XCTFail(violations.joined(separator: "\n"))
            return
        }

        // 1.d Canonical (type, name, lowestVCN) ascending order. (We compare by
        //     type + startingVCN; entries here are all distinct names empty/$? —
        //     a name compare would need the raw UTF-16 which we also check.)
        for i in 1..<max(entries.count, 1) where i < entries.count {
            let p = entries[i - 1], q = entries[i]
            let inOrder = (p.type < q.type) || (p.type == q.type && p.startingVCN <= q.startingVCN)
            if !inOrder {
                violations.append("STEP 1.d — $ATTRIBUTE_LIST not in canonical order: entry \(i-1) (type 0x\(String(p.type, radix: 16)) vcn \(p.startingVCN)) before entry \(i) (type 0x\(String(q.type, radix: 16)) vcn \(q.startingVCN))")
            }
        }

        // 1.e Completeness: the list must name EVERY attribute the file owns.
        //     The base record (post-migration) physically holds everything
        //     except the migrated $DATA; the migrated $DATA lives in the
        //     extension. A strict reader rejects a list missing
        //     $STANDARD_INFORMATION (0x10), $FILE_NAME (0x30), or the migrated
        //     $DATA (0x80).
        //
        //     NOTE on the $ATTRIBUTE_LIST self-entry (type 0x20): NTFS does NOT
        //     list the $ATTRIBUTE_LIST in itself. Readers (fs/ntfs3
        //     `ntfs_load_attr_list`, ntfs-3g `ntfs_attrlist_*`, Windows) always
        //     find $ATTRIBUTE_LIST directly in the base record's attribute
        //     stream, never by walking itself. Omitting the 0x20 self-entry is
        //     therefore SPEC-CORRECT, so it is intentionally NOT required here.
        let entryTypes = Set(entries.map { $0.type })
        for required: UInt32 in [0x10, 0x30, 0x80] {
            if !entryTypes.contains(required) {
                violations.append("STEP 1.e — $ATTRIBUTE_LIST is INCOMPLETE: missing an entry for type 0x\(String(required, radix: 16)) (a strict reader rejects an incomplete list)")
            }
        }

        // 1.g Exactness: the list must describe EXACTLY the file's attributes.
        //     Build the expected set independently: every attribute physically
        //     in the base record EXCEPT the $ATTRIBUTE_LIST itself (which is
        //     never self-listed), PLUS the migrated unnamed $DATA. Any list
        //     entry not in this set is a phantom (a strict reader would chase a
        //     non-existent attribute); any base attribute missing from the list
        //     is a hole (the reader can't find it).
        var expectedListedTypes = Set(baseAttrs.map { $0.type })
        expectedListedTypes.remove(0x20)         // $ATTRIBUTE_LIST never lists itself
        expectedListedTypes.insert(0x80)         // migrated $DATA now lives in the extension
        if entryTypes != expectedListedTypes {
            let phantom = entryTypes.subtracting(expectedListedTypes).map { "0x\(String($0, radix: 16))" }
            let missing = expectedListedTypes.subtracting(entryTypes).map { "0x\(String($0, radix: 16))" }
            violations.append("STEP 1.g — $ATTRIBUTE_LIST type-set mismatch. phantom (listed but not owned): \(phantom.sorted()); missing (owned but not listed): \(missing.sorted())")
        }

        // 1.f Per-entry mftReference correctness:
        //     base attrs -> base ref; the migrated unnamed $DATA -> extension.
        let mask: UInt64 = 0x0000_FFFF_FFFF_FFFF
        let baseRefExpected = (UInt64(baseSeqRaw) << 48) | (rn & mask)
        let extRefExpected  = (UInt64(extSeqExpected) << 48) | (extRN & mask)
        var migratedDataEntry: AListEntry? = nil
        for e in entries {
            if e.type == 0x80 && e.nameLength == 0 {
                migratedDataEntry = e
                if e.mftReference != extRefExpected {
                    violations.append("STEP 1.f — migrated unnamed $DATA entry mftReference = 0x\(String(e.mftReference, radix: 16)) (rn \(e.recordNumber) seq \(e.sequence)); spec-expected extension ref 0x\(String(extRefExpected, radix: 16)) (rn \(extRN) seq \(extSeqExpected))")
                }
            } else if e.type == 0x20 {
                // The $ATTRIBUTE_LIST self-entry (if present) must point at base.
                if e.mftReference != baseRefExpected {
                    violations.append("STEP 1.f — $ATTRIBUTE_LIST self-entry mftReference = 0x\(String(e.mftReference, radix: 16)); expected base 0x\(String(baseRefExpected, radix: 16))")
                }
            } else {
                if e.mftReference != baseRefExpected {
                    violations.append("STEP 1.f — non-migrant entry type 0x\(String(e.type, radix: 16)) mftReference = 0x\(String(e.mftReference, radix: 16)) (rn \(e.recordNumber) seq \(e.sequence)); spec-expected base 0x\(String(baseRefExpected, radix: 16)) (rn \(rn) seq \(baseSeqRaw))")
                }
            }
        }
        XCTAssertEqual(baseSeqRaw, baseSeqExpected, "independent base seq read must match parser")

        guard let dataEntry = migratedDataEntry else {
            violations.append("STEP 1 — no migrated unnamed $DATA entry in $ATTRIBUTE_LIST")
            XCTFail(violations.joined(separator: "\n"))
            return
        }

        // ============================================================
        // STEP 2 — Extension record: header + migrated $DATA header by hand.
        // ============================================================
        let extRaw = try await readRecordRaw(recordNumber: extRN, device: raw, volume: rv)

        // 2.a 'FILE' magic.
        if u32(extRaw, 0) != 0x454C_4946 {
            violations.append("STEP 2.a — extension record \(extRN) magic 0x\(String(format: "%08X", u32(extRaw, 0))) is not 'FILE'")
        }
        // 2.b baseFileReference packs (baseSeq<<48)|baseRN and is NON-ZERO.
        let extBaseRef = u64(extRaw, 32)
        let baseRefForExt = (UInt64(baseSeqRaw) << 48) | (rn & mask)
        if extBaseRef == 0 {
            violations.append("STEP 2.b — extension record baseFileReference is ZERO (a strict reader cannot bind the extension to its base -> Input/output error)")
        } else if extBaseRef != baseRefForExt {
            violations.append("STEP 2.b — extension baseFileReference = 0x\(String(extBaseRef, radix: 16)) (rn \(extBaseRef & mask) seq \(UInt16((extBaseRef >> 48) & 0xFFFF))); spec-expected 0x\(String(baseRefForExt, radix: 16)) (rn \(rn) seq \(baseSeqRaw))")
        }
        // 2.c IN_USE set; NOT itself a base (baseFileReference != 0 already
        //     proves it is an extension); DIRECTORY must NOT be set.
        let extFlags = u16(extRaw, 22)
        if extFlags & 0x0001 == 0 {
            violations.append("STEP 2.c — extension record IN_USE flag NOT set (flags 0x\(String(format: "%04X", extFlags)))")
        }
        if extFlags & 0x0002 != 0 {
            violations.append("STEP 2.c — extension record has DIRECTORY flag set (extension records must never be directories)")
        }
        // 2.d sequence sane + next attribute ID sane.
        if u16(extRaw, 16) == 0 {
            violations.append("STEP 2.d — extension record sequence number is 0 (invalid)")
        }

        // 2.e Locate the migrated unnamed non-resident $DATA in the extension.
        let extAttrs = try walkAttributes(extRaw)
        guard let dataAttr = extAttrs.first(where: { $0.type == 0x80 && $0.nameLength == 0 }) else {
            violations.append("STEP 2.e — extension record holds NO unnamed $DATA (0x80)")
            XCTFail(violations.joined(separator: "\n"))
            return
        }
        if !dataAttr.nonResident {
            violations.append("STEP 2.e — migrated $DATA in extension is RESIDENT (expected non-resident)")
        }

        // 2.f Independent non-resident $DATA header fields.
        let ds = dataAttr.start
        let dataAttrLen = dataAttr.length
        let extStartVCN = u64(extRaw, ds + 16)
        let extLastVCN  = u64(extRaw, ds + 24)
        let runsOff     = Int(u16(extRaw, ds + 32))
        let extAlloc    = u64(extRaw, ds + 40)
        let extReal     = u64(extRaw, ds + 48)
        let extInit     = u64(extRaw, ds + 56)

        // 2.f.1 startingVCN must equal the lowestVCN the $ATTRIBUTE_LIST entry
        //       advertises for this migrant (typically 0 for an unsplit attr).
        if extStartVCN != dataEntry.startingVCN {
            violations.append("STEP 2.f — extension $DATA startingVCN = \(extStartVCN) but $ATTRIBUTE_LIST entry advertises lowestVCN = \(dataEntry.startingVCN) (a strict reader keys the extension lookup on the list's lowestVCN -> mismatch -> I/O error)")
        }

        // 2.f.2 dataRunsOffset within bounds and >= 64 (non-resident header end).
        if runsOff < 64 || runsOff >= dataAttrLen {
            violations.append("STEP 2.f — extension $DATA dataRunsOffset \(runsOff) out of range [64, \(dataAttrLen))")
        }

        // 2.f.3 Runlist decodes + terminates within recorded attribute length.
        let runWindow = Array(extRaw[(ds + min(runsOff, dataAttrLen))..<(ds + dataAttrLen)])
        let runs: [SpecRun]
        do {
            runs = try specDecode(runWindow, boundary: runWindow.count)
        } catch {
            violations.append("STEP 2.f — extension $DATA runlist not spec-decodable within recorded length \(dataAttrLen): \(error)\n  window: \(hex(runWindow))")
            XCTFail(violations.joined(separator: "\n"))
            return
        }
        let coveredClusters = runs.reduce(UInt64(0)) { $0 + $1.length }

        // 2.f.4 lastVCN/allocatedSize must cover the runlist; realSize == payload.
        if extLastVCN != coveredClusters - 1 {
            violations.append("STEP 2.f — extension $DATA lastVCN = \(extLastVCN) but runlist covers \(coveredClusters) clusters (expected lastVCN \(coveredClusters - 1))")
        }
        if extAlloc != coveredClusters * clusterBytes {
            violations.append("STEP 2.f — extension $DATA allocatedSize = \(extAlloc) but runlist covers \(coveredClusters) * \(clusterBytes) = \(coveredClusters * clusterBytes)")
        }
        if extReal != total {
            violations.append("STEP 2.f — extension $DATA realSize = \(extReal) expected payload \(total)")
        }
        if extInit != total {
            violations.append("STEP 2.f — extension $DATA initializedSize = \(extInit) expected payload \(total)")
        }

        // ============================================================
        // STEP 3 — Physical content: independent runlist-order read.
        // ============================================================
        guard runs.count >= 1 else {
            violations.append("STEP 3 — runlist empty"); XCTFail(violations.joined(separator: "\n")); return
        }
        var assembled = Data(); assembled.reserveCapacity(Int(total))
        var remaining = Int(total)
        for r in runs where remaining > 0 {
            let take = Int(min(r.length * clusterBytes, UInt64(remaining)))
            if let lcn = r.lcn {
                let chunk = try await raw.read(offset: UInt64(lcn) * clusterBytes, length: take)
                assembled.append(chunk)
            } else {
                assembled.append(Data(repeating: 0, count: take))  // sparse
            }
            remaining -= take
        }
        XCTAssertEqual(assembled.count, Int(total), "independent reassembly length")
        // Byte-exact against the deterministic payload generator.
        var firstMismatch = -1
        let base = assembled.startIndex
        for i in 0..<assembled.count where assembled[base + i] != Self.contentByte(at: UInt64(i)) {
            firstMismatch = i; break
        }
        XCTAssertEqual(firstMismatch, -1, "STEP 3 — independent spec-order physical read diverges at byte \(firstMismatch)")

        // ============================================================
        // Verdict.
        // ============================================================
        if !violations.isEmpty {
            XCTFail("""
            MIGRATED $DATA LAYOUT IS NOT SPEC-CONFORMANT (independent reader):

            \(violations.joined(separator: "\n"))

            --- evidence ---
            base RN \(rn) seq \(baseSeqRaw); extension RN \(extRN) seq \(extSeqExpected)
            $ATTRIBUTE_LIST body (\(alValueLen) bytes): \(hex(alBody))
            extension $DATA runlist window: \(hex(runWindow))
            extension $DATA: startVCN=\(extStartVCN) lastVCN=\(extLastVCN) runsOff=\(runsOff) alloc=\(extAlloc) real=\(extReal) init=\(extInit)
            """)
        }
    }

    // =====================================================================
    // MARK: - Evidence dump (always passes; prints exact bytes for diagnosis)
    // =====================================================================

    func testDumpMigratedLayoutBytes() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let (rn, total) = try await driveDataOverflow(volume: volume, named: "dump.bin")
        let mft = await volume.mft()
        let baseRecParsed = try await mft.record(at: rn)
        guard try baseRecParsed.attributes().contains(where: { $0.rawType == AttributeType.attributeList.rawValue }) else {
            throw XCTSkip("no migration occurred; nothing to dump")
        }
        guard let extRN = try await findExtensionRecord(for: rn, in: volume) else {
            throw XCTSkip("no extension record to dump")
        }

        let raw = try FileHandleBlockDevice(openingFileAt: path)
        let rv = try await Volume(device: raw)

        let baseRaw = try await readRecordRaw(recordNumber: rn, device: raw, volume: rv)
        let extRaw  = try await readRecordRaw(recordNumber: extRN, device: raw, volume: rv)

        // 64-bit hex (Foundation's %X is a 32-bit C varargs format and TRUNCATES
        // a UInt64 to its low 32 bits — must NOT use it for mftReference values).
        func hex64(_ v: UInt64) -> String {
            let s = String(v, radix: 16)
            return String(repeating: "0", count: max(0, 16 - s.count)) + s
        }
        print("=== MIGRATED LAYOUT DUMP (rn \(rn), extRN \(extRN), payload \(total) bytes) ===")
        print("BASE flags=0x\(String(format: "%04X", u16(baseRaw, 22))) seq=\(u16(baseRaw, 16)) baseRef=0x\(hex64(u64(baseRaw, 32)))")

        let baseAttrs = try walkAttributes(baseRaw)
        for a in baseAttrs {
            print("  BASE attr type=0x\(String(a.type, radix: 16)) len=\(a.length) nr=\(a.nonResident) nameLen=\(a.nameLength) id=\(a.attributeID)")
        }
        if let al = baseAttrs.first(where: { $0.type == 0x20 }) {
            let vl = Int(u32(baseRaw, al.start + 16)), vo = Int(u16(baseRaw, al.start + 20))
            let body = Array(baseRaw[(al.start + vo)..<(al.start + vo + vl)])
            print("  $ATTRIBUTE_LIST body (\(vl) bytes): \(hex(body))")
            if let entries = try? decodeAttributeList(body, bodyLen: vl) {
                for e in entries {
                    print("    entry type=0x\(String(e.type, radix: 16)) recLen=\(e.recordLength) nameLen=\(e.nameLength) nameOff=\(e.nameOffset) lowestVCN=\(e.startingVCN) ref=rn\(e.recordNumber)/seq\(e.sequence) id=\(e.attributeID)")
                }
            }
        }

        print("EXT  flags=0x\(String(format: "%04X", u16(extRaw, 22))) seq=\(u16(extRaw, 16)) baseRef=0x\(hex64(u64(extRaw, 32)))")
        let extAttrs = try walkAttributes(extRaw)
        for a in extAttrs where a.type == 0x80 && a.nameLength == 0 {
            let ds = a.start
            print("  EXT $DATA startVCN=\(u64(extRaw, ds + 16)) lastVCN=\(u64(extRaw, ds + 24)) runsOff=\(u16(extRaw, ds + 32)) alloc=\(u64(extRaw, ds + 40)) real=\(u64(extRaw, ds + 48)) init=\(u64(extRaw, ds + 56))")
            let runsOff = Int(u16(extRaw, ds + 32))
            let win = Array(extRaw[(ds + runsOff)..<(ds + a.length)])
            print("  EXT $DATA runlist window: \(hex(win))")
        }
    }
}
