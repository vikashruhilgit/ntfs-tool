import XCTest
@testable import NTFSCore

/// v0.5 Bug B regression guard: `createFile`'s `$I30` ↔ MFT-record commit
/// is atomic with respect to abort. Concretely the post-abort on-disk
/// state must NEVER be `(MFT record absent, $I30 entry present)` — the
/// dangling-entry state `verify --deep` flagged on the v0.5 hardware run.
///
/// The fix's commit ordering (see `Volume.createFile` big comment):
///   1) compute everything in memory
///   2) durably write the new MFT record (slot becomes IN_USE)
///   3) commit the parent's `$I30` entry
///   on throw between (2) and (3): reclaim the MFT slot — clean rollback.
///   on throw AFTER (3) has touched any parent-side byte: KEEP the MFT
///     slot IN_USE — surface as an orphan base record, NOT a dangling
///     `$I30` entry. `ntfsctl reclaim-orphans` is the recovery path.
///
/// These tests drive the new `_setCreateFileFaultHook` `#if DEBUG` seam
/// to force a throw at each phase and audit the resulting on-disk state
/// using **independent raw-byte decoders** (AC-6): no `Volume.enumerate`,
/// no `MFTRecord.parse`, no `IndexRoot.parse`, no `Attribute.iterate`.
/// The decoders below walk attribute headers and index entries by hand
/// against bytes returned from `device.read(offset:length:)`.
final class CreateFileAtomicityTests: XCTestCase {

    // MARK: - Independent raw-byte decoders (AC-6)

    /// Read one MFT record's on-disk bytes (USA still applied). The
    /// fixture's MFT is contiguous from `boot.mftCluster`, so for any
    /// early user record the byte offset is just
    /// `volume.mftByteOffset + recordNumber * volume.mftRecordSizeBytes`.
    private func readRawMFTRecord(volume: Volume, recordNumber: UInt64) async throws -> Data {
        let recordSize = UInt64(volume.mftRecordSizeBytes)
        let offset = volume.mftByteOffset + recordNumber * recordSize
        return try await volume.device.read(offset: offset, length: Int(recordSize))
    }

    /// Independent USA reverse-fixup. NTFS multi-sector records replace
    /// the last 2 bytes of every sector with a sentinel; on read we
    /// verify the sentinel matches USA[0] and restore the original
    /// bytes from USA[1..N]. Inlined here so this audit does not depend
    /// on `UpdateSequenceArray.applyFixup` (whose semantics are
    /// orthogonal to the shape under test, but inlining keeps AC-6's
    /// "no NTFSCore decoder" boundary maximally crisp).
    private func independentlyApplyUSA(
        rawRecord raw: Data,
        sectorSize: Int = 512
    ) throws -> Data {
        let usaOffset = Int(rawLE16(raw, at: 4))
        let usaCount  = Int(rawLE16(raw, at: 6))
        let sentinel  = rawLE16(raw, at: usaOffset)
        let fixups    = usaCount - 1
        XCTAssertEqual(fixups, raw.count / sectorSize,
                       "USA fixup count must match record_size / sector_size")
        var out = raw
        for i in 0..<fixups {
            let blockTail = (i + 1) * sectorSize - 2
            let onDiskSentinel = rawLE16(out, at: blockTail)
            XCTAssertEqual(onDiskSentinel, sentinel,
                           "USA sentinel mismatch in sector \(i) — torn write or wrong record bytes")
            let usaSlot = usaOffset + 2 * (i + 1)
            out[out.startIndex + blockTail]     = out[out.startIndex + usaSlot]
            out[out.startIndex + blockTail + 1] = out[out.startIndex + usaSlot + 1]
        }
        return out
    }

    /// Read offset 22 of the MFT record header for the IN_USE bit.
    /// Offset 22 is in sector 0 (well before the sector-0 tail at 510),
    /// so USA reverse-fixup is NOT required to read this byte.
    private func mftIsInUse(_ rawRecord: Data) -> Bool {
        let flags = rawLE16(rawRecord, at: 22)
        return (flags & 0x0001) != 0
    }

    /// Walk attributes by hand to find the `$INDEX_ROOT` ($I30 named).
    /// Returns the resident value bytes of the attribute, OR nil if not
    /// found (LARGE_INDEX dirs still HAVE a resident root — they always
    /// do — but the test's `sub/` directory is small and the root holds
    /// the leaf entries directly).
    ///
    /// IMPORTANT: the input MUST be USA-restored bytes (offsets past
    /// 510 must be the real on-disk content, not sentinels).
    private func findIndexRootI30Body(usaFixedRecord: Data) -> Data? {
        let firstAttrOffset = Int(rawLE16(usaFixedRecord, at: 20))
        let usedSize        = Int(rawLE32(usaFixedRecord, at: 24))
        var cursor = firstAttrOffset
        let endMarker: UInt32 = 0xFFFF_FFFF
        while cursor + 16 <= usedSize {
            let typeRaw = rawLE32(usaFixedRecord, at: cursor)
            if typeRaw == endMarker { return nil }
            let length    = Int(rawLE32(usaFixedRecord, at: cursor + 4))
            let nonRes    = usaFixedRecord[usaFixedRecord.startIndex + cursor + 8]
            let nameLen   = usaFixedRecord[usaFixedRecord.startIndex + cursor + 9]
            let nameOff   = Int(rawLE16(usaFixedRecord, at: cursor + 10))
            guard length >= 16, cursor + length <= usedSize else { return nil }

            // Match: type == INDEX_ROOT (0x90), nameLen == 4, name == "$I30".
            if typeRaw == 0x90, nonRes == 0, nameLen == 4 {
                let nameStart = cursor + nameOff
                let nameBytes = usaFixedRecord[(usaFixedRecord.startIndex + nameStart)..<(usaFixedRecord.startIndex + nameStart + 8)]
                // "$I30" in UTF-16LE = 24 00 49 00 33 00 30 00
                let expected: [UInt8] = [0x24, 0x00, 0x49, 0x00, 0x33, 0x00, 0x30, 0x00]
                if Array(nameBytes) == expected {
                    // Resident attribute extension: valueLength @ +16, valueOffset @ +20.
                    let valueLength = Int(rawLE32(usaFixedRecord, at: cursor + 16))
                    let valueOffset = Int(rawLE16(usaFixedRecord, at: cursor + 20))
                    let valueStart  = cursor + valueOffset
                    let valueEnd    = valueStart + valueLength
                    return Data(usaFixedRecord[(usaFixedRecord.startIndex + valueStart)..<(usaFixedRecord.startIndex + valueEnd)])
                }
            }
            cursor += length
        }
        return nil
    }

    /// Walk resident $INDEX_ROOT entries by hand, looking for a filename match.
    /// Returns the matching entry's file-reference (low 48 bits = record
    /// number) or nil if not found.
    ///
    /// On-disk: INDEX_ROOT body starts with 16 bytes of attribute-content
    /// header (type/collation/blockSize/clustersPerBlock) followed by the
    /// 16-byte INDEX_HEADER. INDEX_HEADER.entriesOffset is measured from
    /// the START OF THE INDEX_HEADER, hence absolute offset
    /// `16 + entriesOffset`. Used size is similarly INDEX_HEADER-relative.
    private func findEntryReference(indexRootBody: Data, filename: String) -> UInt64? {
        let entriesOffset = Int(rawLE32(indexRootBody, at: 16))
        let usedSize      = Int(rawLE32(indexRootBody, at: 20))
        var pos = 16 + entriesOffset
        let end = 16 + usedSize
        while pos + 16 <= end {
            let fileRef     = rawLE64(indexRootBody, at: pos + 0)
            let entryLength = Int(rawLE16(indexRootBody, at: pos + 8))
            let keyLength   = Int(rawLE16(indexRootBody, at: pos + 10))
            let flags       = rawLE16(indexRootBody, at: pos + 12)
            guard entryLength >= 16, pos + entryLength <= end else { return nil }
            if (flags & 0x02) != 0 {
                // LAST sentinel — no key
                return nil
            }
            if keyLength >= 66 {
                // Key is a $FILE_NAME body; the filename starts at +66 (after
                // parent ref + 4 FILETIMEs + alloc/real sizes + attrs + ea +
                // nameLen + namespace), encoded UTF-16LE.
                let nameLen = Int(indexRootBody[indexRootBody.startIndex + pos + 16 + 64])
                let nameBytesStart = pos + 16 + 66
                let nameBytesEnd   = nameBytesStart + nameLen * 2
                if nameBytesEnd <= pos + entryLength,
                   let decoded = decodeUTF16LEBytes(indexRootBody, from: nameBytesStart, byteCount: nameLen * 2),
                   decoded == filename {
                    return fileRef & 0x0000_FFFF_FFFF_FFFF
                }
            }
            pos += entryLength
        }
        return nil
    }

    // Tiny independent endianness helpers — `Data.readU*LE` exists in
    // NTFSCore but we read bytes ourselves so audit doesn't depend on
    // any of the project's parsing primitives.

    private func rawLE16(_ d: Data, at: Int) -> UInt16 {
        let lo = UInt16(d[d.startIndex + at])
        let hi = UInt16(d[d.startIndex + at + 1])
        return (hi << 8) | lo
    }
    private func rawLE32(_ d: Data, at: Int) -> UInt32 {
        let b0 = UInt32(d[d.startIndex + at])
        let b1 = UInt32(d[d.startIndex + at + 1])
        let b2 = UInt32(d[d.startIndex + at + 2])
        let b3 = UInt32(d[d.startIndex + at + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
    private func rawLE64(_ d: Data, at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(d[d.startIndex + at + i]) << (8 * i)
        }
        return v
    }
    private func decodeUTF16LEBytes(_ d: Data, from: Int, byteCount: Int) -> String? {
        guard byteCount > 0, from + byteCount <= d.count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(byteCount / 2)
        for i in stride(from: 0, to: byteCount, by: 2) {
            units.append(rawLE16(d, at: from + i))
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

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

    /// Pull `sub/`'s MFT record number out of the fixture. `sub/` is the
    /// committed small-$I30 directory in `small.img`; its $INDEX_ROOT
    /// stays resident (it only has one child by default), so the
    /// create-into-resident-I30 code path is what we're exercising.
    private func subDirRecordNumber(volume: Volume) async throws -> UInt64 {
        let root = try await volume.enumerate(directory: 5)
        guard let sub = root.first(where: { $0.name == "sub" && $0.fileName.namespace != .dos }) else {
            throw XCTSkip("fixture root doesn't contain 'sub/' — regenerate via scripts/make_test_images.sh")
        }
        return sub.recordNumber
    }

    // MARK: - Tests

    /// AC-3 control: happy path. No fault hook. `createFile` succeeds;
    /// post-state has both the $I30 entry AND the in-use MFT record.
    /// Guards against the seam accidentally leaking into non-test flow.
    func testHappyPathCreateLeavesConsistentState() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)
        let filename = "happy-control.txt"

        let recordNumber = try await volume.createFile(named: filename, inDirectory: parentRN)

        // Independent audit on a fresh device.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)

        let parentRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: parentRN)
        let parentFixed = try independentlyApplyUSA(rawRecord: parentRaw)
        let i30Body = findIndexRootI30Body(usaFixedRecord: parentFixed)
        XCTAssertNotNil(i30Body, "parent must have a resident $INDEX_ROOT:$I30")
        let foundRef = findEntryReference(indexRootBody: i30Body!, filename: filename)
        XCTAssertEqual(foundRef, recordNumber,
                       "$I30 entry must reference the newly-allocated MFT record")

        let childRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: recordNumber)
        XCTAssertTrue(mftIsInUse(childRaw),
                      "child MFT record must be IN_USE after a successful createFile")
    }

    /// AC-3 safe-window: throw between MFT-record commit and $I30 commit.
    /// Post-state MUST be clean: $I30 does NOT contain the new entry AND
    /// the MFT slot has been reclaimed (IN_USE cleared).
    func testFaultBeforeI30CommitRollsBackCleanly() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        // Pre-record the slot the create WOULD have used so we can audit it.
        let mft = await volume.mft()
        let expectedSlot = try await mft.findFreeRecordNumber()
        let filename = "fault-pre-i30.txt"

        await volume._setCreateFileFaultHook(.afterMFTWriteBeforeI30Commit)
        do {
            _ = try await volume.createFile(named: filename, inDirectory: parentRN)
            XCTFail("createFile must throw under afterMFTWriteBeforeI30Commit fault hook")
        } catch {
            // expected
        }

        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)

        let parentRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: parentRN)
        let parentFixed = try independentlyApplyUSA(rawRecord: parentRaw)
        if let i30 = findIndexRootI30Body(usaFixedRecord: parentFixed) {
            XCTAssertNil(findEntryReference(indexRootBody: i30, filename: filename),
                         "$I30 must NOT contain a pre-I30-commit fault's filename")
        }

        let childRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: expectedSlot)
        XCTAssertFalse(mftIsInUse(childRaw),
                       "MFT slot must be reclaimed (IN_USE=0) after pre-I30-commit fault")
    }

    /// AC-3 dangerous window: throw AFTER $I30 commit succeeded but BEFORE
    /// `createFile` returns. Under the CORRECT discipline:
    ///   - $I30 entry is durably committed (it reached disk before the throw)
    ///   - MFT record IS still IN_USE (we did NOT reclaim it on this path)
    ///
    /// The forbidden state — `(record absent, $I30 present)` — must
    /// NEVER hold. Pre-fix discipline would reclaim the MFT slot here and
    /// leave a dangling $I30 entry; this assertion is the regression guard.
    func testFaultAfterI30CommitLeavesOrphanNotDangling() async throws {
        guard fixtureExists("small.img") else {
            throw XCTSkip("fixture missing; run scripts/make_test_images.sh")
        }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)
        let parentRN = try await subDirRecordNumber(volume: volume)

        let mft = await volume.mft()
        let expectedSlot = try await mft.findFreeRecordNumber()
        let filename = "fault-post-i30.txt"

        await volume._setCreateFileFaultHook(.afterI30CommitBeforeReturn)
        do {
            _ = try await volume.createFile(named: filename, inDirectory: parentRN)
            XCTFail("createFile must throw under afterI30CommitBeforeReturn fault hook")
        } catch {
            // expected
        }

        // Audit on a fresh device. The whole point of AC-6 is that the
        // assertions below decode raw bytes — they NEVER round-trip
        // through Volume.enumerate or the IndexRoot parser.
        let reader = try FileHandleBlockDevice(openingFileForUpdateAt: path, lockExclusive: false)
        let auditVol = try await Volume(device: reader)

        let parentRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: parentRN)
        let parentFixed = try independentlyApplyUSA(rawRecord: parentRaw)
        let i30Body = findIndexRootI30Body(usaFixedRecord: parentFixed)
        XCTAssertNotNil(i30Body, "parent must still have a resident $INDEX_ROOT:$I30")
        let foundRef = findEntryReference(indexRootBody: i30Body!, filename: filename)
        XCTAssertEqual(foundRef, expectedSlot,
                       "$I30 entry must be present and reference expectedSlot — proves the commit reached disk before the fault")

        let childRaw = try await readRawMFTRecord(volume: auditVol, recordNumber: expectedSlot)
        let childInUse = mftIsInUse(childRaw)

        // The MOST IMPORTANT assertion in this entire test file:
        // the post-abort state MUST NOT be `(record absent, $I30 present)`.
        XCTAssertTrue(
            childInUse,
            "INVARIANT VIOLATION: $I30 contains an entry for \(filename) → recnum \(expectedSlot), but that MFT record has IN_USE=0. This is the v0.5 hardware-observed 'dangling $I30 entry' state — the fix should leave the MFT slot IN_USE (orphan-base, recoverable via reclaim-orphans), NOT free it. Pre-fix discipline failed exactly this assertion."
        )
    }
}
