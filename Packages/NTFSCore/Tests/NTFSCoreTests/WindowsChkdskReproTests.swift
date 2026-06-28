import XCTest
@testable import NTFSCore

/// Reproduction harness for the real-Windows `chkdsk /f` catastrophe (see
/// memory real-windows-chkdsk-fail-postfix): chkdsk deletes the `$FILE_NAME`
/// (0x30) attribute from every file/dir record we write, orphaning all data.
/// ntfs-3g and our own reader accept these records; chkdsk does not.
///
/// This test drives the FULL createFile + write path on a freshly-formatted
/// image, then runs a STRICT, chkdsk-style structural validator over each
/// record's logical (post-fix-up) bytes — looking for whatever the handoff's
/// manual field-diff missed. It does NOT assert pass/fail yet; it prints a
/// detailed dump + the list of structural complaints per record so we can see
/// exactly what chkdsk would reject.
final class WindowsChkdskReproTests: XCTestCase {

    private func makeBlankImage(sizeMiB: Int = 64) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let path = tmpDir.appendingPathComponent("chkdsk-repro-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()
        return path
    }

    // MARK: - strict chkdsk-style validator over logical record bytes

    private func u16(_ b: Data, _ o: Int) -> Int { Int(b[b.startIndex + o]) | (Int(b[b.startIndex + o + 1]) << 8) }
    private func u32(_ b: Data, _ o: Int) -> Int {
        Int(b[b.startIndex + o]) | (Int(b[b.startIndex + o + 1]) << 8)
        | (Int(b[b.startIndex + o + 2]) << 16) | (Int(b[b.startIndex + o + 3]) << 24)
    }

    /// Returns (problems, humanDump).
    private func validate(_ b: Data, label: String) -> (problems: [String], dump: String) {
        var p: [String] = []
        var d = "== \(label) ==\n"
        let magic = u32(b, 0)
        let usaOff = u16(b, 4), usaCount = u16(b, 6)
        let firstAttr = u16(b, 20)
        let flags = u16(b, 22)
        let used = u32(b, 24), alloc = u32(b, 28)
        let nextID = u16(b, 40)
        d += "magic=0x\(String(magic, radix:16)) usaOff=\(usaOff) usaCount=\(usaCount) firstAttr=\(firstAttr) flags=0x\(String(flags, radix:16)) used=\(used) alloc=\(alloc) nextAttrID=\(nextID)\n"

        if magic != 0x454C4946 { p.append("magic != FILE") }
        if used % 8 != 0 { p.append("used_size \(used) NOT 8-aligned") }
        if used > alloc { p.append("used_size \(used) > alloc \(alloc)") }

        var o = firstAttr
        var maxID = -1
        var sawEnd = false
        var guardCount = 0
        var prevType = -1
        var seenIDs: [Int] = []
        while o + 4 <= alloc {
            guardCount += 1; if guardCount > 64 { p.append("attr walk runaway"); break }
            let t = u32(b, o)
            if t == 0xFFFFFFFF {
                sawEnd = true
                let endPlus4 = o + 4
                let aligned = (endPlus4 + 7) & ~7
                d += "  @\(o) END  (endMarker+4=\(endPlus4), align8=\(aligned))\n"
                if used != endPlus4 && used != aligned {
                    p.append("used_size \(used) != endMarker+4 (\(endPlus4)) and != align8 (\(aligned))")
                }
                // Windows convention is align8(endMarker+4).
                if used != aligned {
                    p.append("used_size \(used) != Windows-canonical align8(endMarker+4)=\(aligned)")
                }
                break
            }
            if o + 16 > alloc { p.append("attr header at \(o) runs off record"); break }
            let len = u32(b, o + 4)
            let nonres = b[b.startIndex + o + 8]
            let nameLen = Int(b[b.startIndex + o + 9])
            let nameOff = u16(b, o + 10)
            let id = u16(b, o + 14)
            let attrFlags = u16(b, o + 12)
            let indexedByte = b[b.startIndex + o + 22]
            if seenIDs.contains(id) { p.append("DUPLICATE instance ID \(id) at attr 0x\(String(t,radix:16)) @\(o)") }
            seenIDs.append(id)
            if id >= nextID { p.append("attr 0x\(String(t,radix:16)) @\(o): instance ID \(id) >= nextAttributeID(first-available) \(nextID) — chkdsk deletes this") }
            maxID = max(maxID, id)
            // chkdsk: attribute records must appear in ascending type order.
            if t < prevType { p.append("attr 0x\(String(t,radix:16)) @\(o): type out of ascending order (prev 0x\(String(prevType,radix:16)))") }
            prevType = t
            var extra = ""
            if nonres == 0 {
                let vlen = u32(b, o + 16)
                let voff = u16(b, o + 20)
                extra = " RES vlen=\(vlen) voff=\(voff) attrFlags=0x\(String(attrFlags,radix:16)) idxByte=\(indexedByte)"
                // chkdsk: resident value offset must be 8-byte aligned.
                if voff % 8 != 0 { p.append("attr 0x\(String(t,radix:16)) @\(o): value offset \(voff) NOT 8-aligned") }
                if voff + vlen > len { p.append("attr 0x\(String(t,radix:16)) @\(o): voff(\(voff))+vlen(\(vlen)) > len(\(len))") }
                if nameLen > 0 {
                    if nameOff < 24 { p.append("attr 0x\(String(t,radix:16)) @\(o): named but nameOff \(nameOff) < 24") }
                    if nameOff + nameLen*2 > voff { p.append("attr 0x\(String(t,radix:16)) @\(o): name overlaps value") }
                }
                if t == 0x30 { // $FILE_NAME
                    let bd = o + voff
                    let fnNameChars = Int(b[b.startIndex + bd + 64])
                    let ns = Int(b[b.startIndex + bd + 65])
                    let allocSz = "\(u32(b, bd+40))+\(u32(b, bd+44))<<32"
                    let realSz = "\(u32(b, bd+48))+\(u32(b, bd+52))<<32"
                    extra += " FN nameChars=\(fnNameChars) ns=\(ns) alloc=[\(allocSz)] real=[\(realSz)]"
                    if vlen != 66 + fnNameChars*2 { p.append("$FILE_NAME @\(o): vlen \(vlen) != 66+nameChars*2 (\(66+fnNameChars*2))") }
                    if ns > 3 { p.append("$FILE_NAME @\(o): namespace \(ns) > 3") }
                    if voff != 24 { p.append("$FILE_NAME @\(o): value offset \(voff) != 24") }
                    // $FILE_NAME is indexed in $I30: resident "indexed" flag
                    // (0x16) MUST be 1, or chkdsk deletes the attribute as
                    // corrupt. Verified against ntfs-3g reference records.
                    if indexedByte != 1 { p.append("$FILE_NAME @\(o): resident indexed flag (0x16) = \(indexedByte), must be 1 — chkdsk deletes $FILE_NAME without it") }
                }
            } else {
                extra = " NONRES sVCN=\(u32(b,o+16)) eVCN=\(u32(b,o+24)) runOff=\(u16(b,o+32))"
            }
            d += "  @\(o) type=0x\(String(t,radix:16)) len=\(len) nonres=\(nonres) nameLen=\(nameLen) nameOff=\(nameOff) id=\(id)\(extra)\n"
            if len == 0 { p.append("attr 0x\(String(t,radix:16)) @\(o): len 0"); break }
            if len % 8 != 0 { p.append("attr 0x\(String(t,radix:16)) @\(o): len \(len) NOT 8-aligned") }
            if o + len > used { p.append("attr 0x\(String(t,radix:16)) @\(o): extends to \(o+len) past used_size \(used)") }
            o += len
        }
        if !sawEnd { p.append("no end marker before alloc") }
        if nextID <= maxID { p.append("nextAttrID \(nextID) <= max used id \(maxID)") }
        return (p, d)
    }

    /// chkdsk Stage-2 cross-check: a file's own $FILE_NAME (in its MFT record)
    /// must be byte-identical to the copy in the parent directory's $I30 index
    /// entry. A real Windows `chkdsk E:` reported "index entry … is incorrect" /
    /// "minor file name errors" because createFile stamped the two copies from
    /// two separate `windowsFiletimeNow()` reads microseconds apart. This test
    /// asserts the timestamps + sizes agree.
    func testFileNameMatchesParentIndexEntry() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "FNIDX", volumeSerial: 0xF00D)
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let vol = try await Volume(device: dev)
        // Use a fresh subdirectory as the parent: its $I30 starts as a small
        // (resident) $INDEX_ROOT, so the resident-only index reader below sees
        // the new entries. (Real root is now pre-populated with the 11 system
        // metafiles and is therefore a LARGE_INDEX — its entries live in
        // $INDEX_ALLOCATION, which this test's reader intentionally doesn't walk.)
        let root = try await vol.createFile(named: "fnidx_parent", inDirectory: 5, isDirectory: true)

        func cpFile(_ name: String, _ payload: Data) async throws -> UInt64 {
            let rn = try await vol.createFile(named: name, inDirectory: root,
                                              isDirectory: false, dataSize: UInt64(payload.count))
            var pending: Data? = payload
            try await vol.writeFile(at: rn, totalSize: UInt64(payload.count)) { defer { pending = nil }; return pending ?? Data() }
            return rn
        }
        let resident = try await cpFile("resident.txt", Data("hi\n".utf8))
        let nonresident = try await cpFile("big.bin", Data(repeating: 0x42, count: 8192))

        let mft = await vol.mft()

        func u64(_ b: Data, _ o: Int) -> UInt64 {
            var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[b.startIndex + o + i]) << (8 * i) }; return v
        }
        // Extract the file's own $FILE_NAME body (cre,mod,mftChg,acc,alloc,real).
        func ownFN(_ rn: UInt64) async throws -> [UInt64] {
            let b = try await mft.record(at: rn).bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = u32(b, o); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == 0x30 { let k = o + u16(b, o + 20)
                    return [u64(b,k+8), u64(b,k+16), u64(b,k+24), u64(b,k+32), u64(b,k+40), u64(b,k+48)] }
                o += l
            }
            return []
        }
        // Extract the $I30 index-entry $FILE_NAME body for `name` from root's $INDEX_ROOT.
        func indexFN(_ name: String) async throws -> [UInt64] {
            let b = try await mft.record(at: root).bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = u32(b, o); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == 0x90 {
                    let body = o + u16(b, o + 20)
                    let entriesOff = u32(b, body + 16)         // rel to INDEX_HEADER at body+16
                    var e = body + 16 + entriesOff
                    while e + 16 <= b.count {
                        let flags = u16(b, e + 12); let elen = u16(b, e + 8)
                        if flags & 2 != 0 { break }            // LAST
                        let k = e + 16
                        let nl = Int(b[b.startIndex + k + 64])
                        var units = [UInt16](); for i in 0..<nl { units.append(UInt16(u16(b, k + 66 + 2*i))) }
                        let nm = String(decoding: units, as: UTF16.self)
                        if nm == name {
                            return [u64(b,k+8), u64(b,k+16), u64(b,k+24), u64(b,k+32), u64(b,k+40), u64(b,k+48)]
                        }
                        if elen == 0 { break }; e += elen
                    }
                }
                o += l
            }
            return []
        }

        // Namespace must be POSIX (0). A Win32 (1) name with no DOS alias is
        // what Windows self-healing rewrites to POSIX, i.e. the "minor file
        // name errors" chkdsk reported. Created files must match Windows here.
        func namespaceOf(_ rn: UInt64) async throws -> Int {
            let b = try await mft.record(at: rn).bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = u32(b, o); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == 0x30 { return Int(b[b.startIndex + o + u16(b, o + 20) + 65]) }
                o += l
            }
            return -1
        }

        for (rn, name) in [(resident, "resident.txt"), (nonresident, "big.bin")] {
            let own = try await ownFN(rn)
            let idx = try await indexFN(name)
            XCTAssertFalse(own.isEmpty, "\(name): no own $FILE_NAME")
            XCTAssertFalse(idx.isEmpty, "\(name): no $I30 entry")
            XCTAssertEqual(own, idx,
                "\(name): file $FILE_NAME [cre,mod,mftChg,acc,alloc,real]=\(own) != $I30 index entry \(idx) — chkdsk flags 'index entry is incorrect'")
            let ns = try await namespaceOf(rn)
            XCTAssertEqual(ns, 0, "\(name): $FILE_NAME namespace \(ns) must be 0 (POSIX) — Win32(1) without a DOS alias is what chkdsk flags")
        }

        // Directory attributes must match Windows-authored dirs byte-for-byte:
        // $STD_INFO fileAttributes = 0, $FILE_NAME fileAttributes = 0x10000000
        // (DIRECTORY, no ARCHIVE 0x20). Both the file record and the parent
        // $I30 entry are checked.
        let dirRN = try await vol.createFile(named: "adir", inDirectory: root, isDirectory: true)
        func attrAt(_ rn: UInt64, type: UInt32, field: Int) async throws -> UInt32 {
            let b = try await mft.record(at: rn).bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = UInt32(u32(b, o)); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == type { return UInt32(u32(b, o + u16(b, o + 20) + field)) }
                o += l
            }
            return 0xDEAD
        }
        let dirStd = try await attrAt(dirRN, type: 0x10, field: 32)
        let dirFN  = try await attrAt(dirRN, type: 0x30, field: 56)
        XCTAssertEqual(dirStd, 0, "directory $STD_INFO fileAttributes must be 0 (got 0x\(String(dirStd, radix: 16)))")
        XCTAssertEqual(dirFN, 0x10000000, "directory $FILE_NAME fileAttributes must be 0x10000000 / DIRECTORY-no-ARCHIVE (got 0x\(String(dirFN, radix: 16)))")
        // And the parent $I30 entry's $FILE_NAME flags must match.
        let dirIdxFlags = try await { () async throws -> UInt32 in
            let b = try await mft.record(at: root).bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = u32(b, o); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == 0x90 {
                    let body = o + u16(b, o + 20)
                    var e = body + 16 + u32(b, body + 16)
                    while e + 16 <= b.count {
                        let fl = u16(b, e + 12); let el = u16(b, e + 8)
                        if fl & 2 != 0 { break }
                        let k = e + 16; let nl = Int(b[b.startIndex + k + 64])
                        var units = [UInt16](); for i in 0..<nl { units.append(UInt16(u16(b, k + 66 + 2*i))) }
                        if String(decoding: units, as: UTF16.self) == "adir" { return UInt32(u32(b, k + 56)) }
                        if el == 0 { break }; e += el
                    }
                }
                o += l
            }
            return 0xDEAD
        }()
        XCTAssertEqual(dirIdxFlags, 0x10000000, "directory $I30 entry $FILE_NAME flags must match the record (got 0x\(String(dirIdxFlags, radix: 16)))")
    }

    /// The EXACT bytes the real Windows drive received at creation: the v3
    /// builder path (securityID inherited → 72-byte $STD_INFO, NO inline 0x50),
    /// with dataSize stamped the way `cp` does (createFile(dataSize:)).
    func testBuilderV3DirectBytesAsWrittenToRealDrive() async throws {
        var problems: [String] = []
        var dump = "\n\n########## BUILDER v3 DIRECT (real-drive creation bytes) ##########\n"
        let cases: [(String, Bool, UInt64, UInt64)] = [
            // name, isDir, dataRealSize, dataAllocatedSize  (as cp/createFile stamps)
            ("doc1.txt", false, 0, 0),           // small resident file: cp now stamps 0/0 (resident = 0 clusters)
            ("large-5mb.bin", false, 5_242_880, 5_242_880),  // non-resident
            ("sub", true, 0, 0),                  // directory
        ]
        for (name, isDir, real, alloc) in cases {
            let builder = MFTRecordBuilder(
                recordSize: 1024, sectorSize: 512,
                recordNumber: 40, sequenceNumber: 1,
                isDirectory: isDir, fileName: name,
                parentReference: (UInt64(1) << 48) | 41,
                securityID: 256,            // v3 path: inherited security id
                securityDescriptor: nil,    // no inline SD
                dataRealSize: isDir ? 0 : real,
                dataAllocatedSize: isDir ? 0 : alloc
            )
            let bytes = try builder.build()
            let (probs, d) = validate(bytes, label: "builder v3: \(name)")
            dump += d
            if probs.isEmpty { dump += "  ✅ no structural complaints\n\n" }
            else { dump += "  ❌ PROBLEMS:\n" + probs.map { "     - \($0)\n" }.joined() + "\n"
                   problems.append(contentsOf: probs.map { "[builder v3 \(name)] \($0)" }) }
        }
        print(dump)
        XCTAssertTrue(problems.isEmpty,
                      "v3 builder structural defects chkdsk would reject:\n" + problems.joined(separator: "\n"))
    }

    /// Rewrite a record's $STD_INFO into the 72-byte v3 form carrying
    /// `securityID`, so `createFile` in that directory takes the v3 path
    /// (no inline 0x50) — matching a real Windows-formatted volume. This is the
    /// path the real-drive catastrophe uses and that the other tests never
    /// exercised end-to-end.
    private func patchToV3(_ vol: Volume, record rn: UInt64, securityID: UInt32) async throws {
        let mft = await vol.mft()
        let rec = try await mft.record(at: rn)
        var b = rec.bytes
        let recordSize = b.count
        let firstAttr = u16(b, 20)
        // STD_INFO is the first attribute.
        let stdOff = firstAttr
        precondition(u32(b, stdOff) == 0x10, "first attr must be $STD_INFO")
        let stdLen = u32(b, stdOff + 4)
        let stdValOff = u16(b, stdOff + 20)
        let stdValLen = u32(b, stdOff + 16)
        if stdValLen >= 72 {
            // already v3: just stamp securityID at body+52
            MFTRecord.writeU32LE(into: &b, at: stdOff + stdValOff + 52, value: securityID)
            try await mft.writeRawRecord(at: rn, postFixupBytes: b)
            return
        }
        // Build a fresh record with STD_INFO expanded to a 72-byte v3 body.
        let newStdLen = ((24 + 72) + 7) & ~7   // 96
        let delta = newStdLen - stdLen
        let oldUsed = u32(b, 24)
        var out = Data(count: recordSize)
        // header + USA + everything up to STD_INFO
        for i in 0..<stdOff { out[out.startIndex + i] = b[b.startIndex + i] }
        // STD_INFO common+resident header (24 bytes) copied, then patched
        for i in 0..<24 { out[out.startIndex + stdOff + i] = b[b.startIndex + stdOff + i] }
        MFTRecord.writeU32LE(into: &out, at: stdOff + 4,  value: UInt32(newStdLen))   // attr length
        MFTRecord.writeU32LE(into: &out, at: stdOff + 16, value: 72)                  // value length
        // body: copy old (48) bytes, zero-extend to 72, stamp securityID @ body+52
        for i in 0..<stdValLen { out[out.startIndex + stdOff + 24 + i] = b[b.startIndex + stdOff + stdValOff + i] }
        MFTRecord.writeU32LE(into: &out, at: stdOff + 24 + 52, value: securityID)
        // shift the rest (other attrs + end marker) by delta
        let restStart = stdOff + stdLen
        for i in 0..<(oldUsed - restStart) {
            out[out.startIndex + restStart + delta + i] = b[b.startIndex + restStart + i]
        }
        // recompute used_size from the (now shifted) end marker
        var o = firstAttr
        while o + 4 <= recordSize {
            if u32(out, o) == 0xFFFFFFFF { break }
            let l = u32(out, o + 4); if l == 0 { break }; o += l
        }
        MFTRecord.writeU32LE(into: &out, at: 24, value: MFTRecord.align8UsedSize(o + 4))
        try await mft.writeRawRecord(at: rn, postFixupBytes: out)
    }

    /// Helper: decode a record's $STD_INFO (v1.2 vs v3 + securityID) and whether
    /// it carries an inline $SECURITY_DESCRIPTOR (0x50).
    private func securityShape(_ b: Data) -> (stdValLen: Int, securityID: Int?, hasInline0x50: Bool) {
        var o = u16(b, 20)
        var stdValLen = 0
        var sid: Int? = nil
        var has50 = false
        var guardC = 0
        while o + 4 <= b.count {
            guardC += 1; if guardC > 64 { break }
            let t = u32(b, o)
            if t == 0xFFFFFFFF { break }
            let len = u32(b, o + 4); if len == 0 { break }
            let nonres = b[b.startIndex + o + 8]
            if t == 0x10, nonres == 0 {
                let vlen = u32(b, o + 16), voff = u16(b, o + 20)
                stdValLen = vlen
                if vlen >= 72 { sid = u32(b, o + voff + 52) }
            }
            if t == 0x50 { has50 = true }
            o += len
        }
        return (stdValLen, sid, has50)
    }

    /// REGRESSION: on a v3 volume (root carries a security_id), `createFile`
    /// MUST emit the v3 record form — a 72-byte $STD_INFO carrying the inherited
    /// security_id and NO inline $SECURITY_DESCRIPTOR (0x50). The real-drive
    /// catastrophe wrote v1.2 records (48-byte $STD_INFO + inherited 0x50) here.
    func testCreateFileInheritsV3SecurityID() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "V3SEC", volumeSerial: 0xBEEF)
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5
        try await patchToV3(vol, record: root, securityID: 256)

        let f1 = try await vol.createFile(named: "v3child.txt", inDirectory: root,
                                          isDirectory: false, dataSize: 12)
        let mft = await vol.mft()
        let rec = try await mft.record(at: f1)
        let shape = securityShape(rec.bytes)
        print("created v3child.txt: stdValLen=\(shape.stdValLen) securityID=\(String(describing: shape.securityID)) hasInline0x50=\(shape.hasInline0x50)")
        XCTAssertEqual(shape.stdValLen, 72, "child $STD_INFO must be 72-byte v3 form")
        XCTAssertEqual(shape.securityID, 256, "child must inherit root's security_id 256")
        XCTAssertFalse(shape.hasInline0x50, "child must NOT carry an inline 0x50 on a v3 volume")
    }

    /// REGRESSION (the 4TB-drive bug): a REAL ntfs-3g/Windows root keeps its SD
    /// as an inline $SECURITY_DESCRIPTOR (0x50) — here NON-resident — alongside a
    /// v1.2 (48-byte) $STD_INFO with NO security_id. The pre-fix `createFile`
    /// read neither (it only looked at a resident 0x50 + the v3 $STD_INFO id), so
    /// it stamped a default inline SD and emitted v1.2 records. The fix reads the
    /// (non-resident) root 0x50 and resolves it through $Secure:$SDS to recover
    /// the registered security_id, so children come out v3 (72-byte $STD_INFO +
    /// that id, NO inline 0x50) — and the id is one chkdsk finds in $Secure.
    func testCreateFileResolvesRealRootSDToV3SecurityID() async throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here.deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("small.img").path
        guard FileManager.default.fileExists(atPath: src) else {
            throw XCTSkip("small.img fixture missing; run scripts/make_test_images.sh")
        }
        // Work on a writable copy — createFile mutates the volume.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("small-rw-\(UUID().uuidString).img").path
        try FileManager.default.copyItem(atPath: src, toPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let vol = try await Volume(device: dev)
        let mft = await vol.mft()

        // Confirm the fixture really is the hard case: v1.2 root, no STD_INFO id.
        let rootShape = securityShape(try await mft.record(at: 5).bytes)
        print("REAL ntfs-3g ROOT (rec 5): stdValLen=\(rootShape.stdValLen) securityID=\(String(describing: rootShape.securityID)) hasInline0x50=\(rootShape.hasInline0x50)")
        XCTAssertEqual(rootShape.stdValLen, 48, "fixture root must be v1.2 (no STD_INFO id) for this to test the real path")

        // The exact path the 4TB cp took: createFile into root.
        let f1 = try await vol.createFile(named: "frombug.txt", inDirectory: 5,
                                          isDirectory: false, dataSize: 9)
        let shape = securityShape(try await mft.record(at: f1).bytes)
        print("created frombug.txt: stdValLen=\(shape.stdValLen) securityID=\(String(describing: shape.securityID)) hasInline0x50=\(shape.hasInline0x50)")
        XCTAssertEqual(shape.stdValLen, 72, "child must be v3 (72-byte $STD_INFO)")
        XCTAssertNotNil(shape.securityID, "child must carry an inherited security_id")
        XCTAssertNotEqual(shape.securityID, 0, "inherited security_id must be non-zero")
        XCTAssertFalse(shape.hasInline0x50, "child must NOT carry an inline 0x50 — the id replaces it")
        // And that id must actually resolve in $Secure:$SDS (what chkdsk checks).
        let resolved = await vol.securityIDIsRegistered(UInt32(shape.securityID!))
        XCTAssertTrue(resolved, "inherited security_id \(shape.securityID!) must exist in $Secure:$SDS")
    }

    func testV3CpPathReproduction() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "REPROV3", volumeSerial: 0xBEEF)
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5
        // Force the v3 path: give root a security_id so children inherit it
        // (no inline 0x50, 72-byte $STD_INFO — exactly like a Windows volume).
        try await patchToV3(vol, record: root, securityID: 256)

        func cpFile(_ name: String, into parent: UInt64, _ payload: Data) async throws -> UInt64 {
            let rn = try await vol.createFile(named: name, inDirectory: parent,
                                              isDirectory: false, dataSize: UInt64(payload.count))
            var pending: Data? = payload
            try await vol.writeFile(at: rn, totalSize: UInt64(payload.count)) { defer { pending = nil }; return pending ?? Data() }
            return rn
        }
        let f1 = try await cpFile("doc_resident.txt", into: root, Data("hello resident\n".utf8))
        let f2 = try await cpFile("big_nonresident.bin", into: root, Data(repeating: 0x41, count: 1_048_576))
        let d1 = try await vol.createFile(named: "subdir", inDirectory: root, isDirectory: true)
        let f3 = try await cpFile("nested.txt", into: d1, Data("nested\n".utf8))

        let mft = await vol.mft()

        // Cross-check each child's $FILE_NAME.parentReference against the
        // parent record's ACTUAL (recordNumber, sequenceNumber). chkdsk
        // validates this; a wrong parent sequence makes the name look
        // orphaned/corrupt. My structural validator does NOT check it, and a
        // fresh file image's trivial sequences would hide a bug — so check it
        // explicitly here.
        func u64(_ b: Data, _ o: Int) -> UInt64 {
            var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[b.startIndex + o + i]) << (8 * i) }; return v
        }
        func fnParentRef(_ rn: UInt64) async throws -> (rec: UInt64, seq: UInt16) {
            let rec = try await mft.record(at: rn)
            let b = rec.bytes
            var o = u16(b, 20)
            while o + 4 <= b.count {
                let t = u32(b, o); if t == 0xFFFFFFFF { break }
                let l = u32(b, o + 4); if l == 0 { break }
                if t == 0x30 {
                    let voff = u16(b, o + 20)
                    let pr = u64(b, o + voff + 0)
                    return (pr & 0x0000_FFFF_FFFF_FFFF, UInt16(pr >> 48))
                }
                o += l
            }
            throw XCTSkip("no $FILE_NAME")
        }
        var refProblems: [String] = []
        for (childRN, parentRN, label) in [(f1, root, "doc_resident.txt"), (f2, root, "big_nonresident.bin"),
                                           (d1, root, "subdir"), (f3, d1, "nested.txt")] {
            let parent = try await mft.record(at: parentRN)
            let got = try await fnParentRef(childRN)
            if got.rec != parentRN || got.seq != parent.sequenceNumber {
                refProblems.append("[\(label)] $FILE_NAME parentRef = (rec \(got.rec), seq \(got.seq)) but parent is (rec \(parentRN), seq \(parent.sequenceNumber))")
            }
        }
        if !refProblems.isEmpty { print("PARENT-REF MISMATCHES:\n" + refProblems.joined(separator: "\n")) }

        let targets: [(UInt64, String)] = [
            (f1, "doc_resident.txt (v3 resident)"),
            (f2, "big_nonresident.bin (v3 non-resident)"),
            (d1, "subdir (v3 directory)"),
            (f3, "nested.txt (v3 file in subdir)"),
        ]
        var allProblems: [String] = []
        var dump = "\n\n########## v3 CP-PATH REPRODUCTION ##########\n"
        for (rn, name) in targets {
            let rec = try await mft.record(at: rn)
            let (probs, d) = validate(rec.bytes, label: "rec \(rn): \(name)")
            dump += d
            if probs.isEmpty { dump += "  ✅ no structural complaints\n\n" }
            else { dump += "  ❌ PROBLEMS:\n" + probs.map { "     - \($0)\n" }.joined() + "\n"
                   allProblems.append(contentsOf: probs.map { "[\(name)] \($0)" }) }
        }
        print(dump)
        XCTAssertTrue(allProblems.isEmpty && refProblems.isEmpty,
                      "v3 cp-path defects:\n" + (allProblems + refProblems).joined(separator: "\n"))
    }


    func testReferenceNamespaces() async throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("small.img").path
        guard FileManager.default.fileExists(atPath: here) else { throw XCTSkip("no small.img") }
        let dev = try FileHandleBlockDevice(openingFileAt: here)
        let vol = try await Volume(device: dev)
        func dump(_ dir: UInt64, _ label: String) async throws {
            let entries = try await vol.enumerate(directory: dir)
            for e in entries {
                print("REFNS \(label)/\(e.name)  namespace=\(e.fileName.namespace) (\(e.fileName.namespace.rawValue))")
            }
        }
        try await dump(5, "root")
    }

    func testDumpAndValidateCreatedRecords() async throws {
        let path = try makeBlankImage()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Format.
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "REPRO", volumeSerial: 0xABCD)
        }

        // Reopen for writing.
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5

        // Mirror `ntfsctl cp` exactly: createFile(dataSize:) then writeFile.
        func cpFile(_ name: String, into parent: UInt64, _ payload: Data) async throws -> UInt64 {
            let rn = try await vol.createFile(named: name, inDirectory: parent,
                                              isDirectory: false, dataSize: UInt64(payload.count))
            var pending: Data? = payload
            try await vol.writeFile(at: rn, totalSize: UInt64(payload.count)) {
                defer { pending = nil }
                return pending ?? Data()
            }
            return rn
        }

        // 1) resident small file (like doc1.txt)
        let f1 = try await cpFile("doc1.txt", into: root, Data("hello resident\n".utf8))
        // 2) non-resident file (like large-5mb.bin, but smaller)
        let f2 = try await cpFile("large.bin", into: root, Data(repeating: 0x5A, count: 8192))
        // 3) subdirectory + child (like sub/nested.txt)
        let d1 = try await vol.createFile(named: "sub", inDirectory: root, isDirectory: true)
        let f3 = try await cpFile("nested.txt", into: d1, Data("nested\n".utf8))

        let mft = await vol.mft()
        let targets: [(UInt64, String)] = [
            (f1, "doc1.txt (resident file)"),
            (f2, "large.bin (non-resident file)"),
            (d1, "sub (directory)"),
            (f3, "nested.txt (file in subdir)"),
            (root, "root (record 5, after inserts)"),
        ]

        var allProblems: [String] = []
        var fullDump = "\n\n########## CHKDSK-STYLE RECORD VALIDATION ##########\n"
        for (rn, name) in targets {
            let rec = try await mft.record(at: rn)
            let (problems, dump) = validate(rec.bytes, label: "rec \(rn): \(name)")
            fullDump += dump
            if problems.isEmpty {
                fullDump += "  ✅ no structural complaints\n\n"
            } else {
                fullDump += "  ❌ PROBLEMS:\n" + problems.map { "     - \($0)\n" }.joined() + "\n"
                allProblems.append(contentsOf: problems.map { "[\(name)] \($0)" })
            }
        }
        print(fullDump)

        XCTAssertTrue(allProblems.isEmpty,
                      "Structural defects found that chkdsk would likely reject:\n" + allProblems.joined(separator: "\n"))
    }

    // MARK: - ntfs-3g reference comparison

    /// Decode + print every attribute of a record in full, with special focus
    /// on $STANDARD_INFORMATION.file_attributes and EACH $FILE_NAME (there may
    /// be more than one: a WIN32 + a DOS companion). This is how we find the
    /// field(s) chkdsk validates that our validator/ntfs-3g/our-reader all miss.
    private func deepDump(_ b: Data, label: String) -> String {
        func hex(_ start: Int, _ count: Int) -> String {
            (0..<count).map { String(format: "%02x", b[b.startIndex + start + $0]) }.joined(separator: " ")
        }
        var d = "== \(label) ==\n"
        d += "  hdr: flags=0x\(String(u16(b,22),radix:16)) hardLinks=\(u16(b,18)) used=\(u32(b,24)) nextAttrID=\(u16(b,40))\n"
        var o = u16(b, 20)
        var fnCount = 0
        var guardC = 0
        while o + 4 <= b.count {
            guardC += 1; if guardC > 64 { break }
            let t = u32(b, o)
            if t == 0xFFFFFFFF { d += "  @\(o) END\n"; break }
            let len = u32(b, o + 4); if len == 0 { break }
            let nonres = b[b.startIndex + o + 8]
            let attrFlags = u16(b, o + 12)
            let id = u16(b, o + 14)
            if nonres == 0 {
                let vlen = u32(b, o + 16), voff = u16(b, o + 20)
                let residentFlags = b[b.startIndex + o + 22]
                d += "  @\(o) type=0x\(String(t,radix:16)) len=\(len) id=\(id) attrFlags=0x\(String(attrFlags,radix:16)) RES vlen=\(vlen) voff=\(voff) residentFlags(0x16)=\(residentFlags)\n"
                let bd = o + voff
                if t == 0x10 {
                    d += "      STD_INFO file_attributes=0x\(String(u32(b, bd+32),radix:16))"
                    d += vlen >= 72 ? " secID=\(u32(b, bd+52)) (v3 72B)\n" : " (v1.2 48B)\n"
                }
                if t == 0x30 {
                    fnCount += 1
                    let nameChars = Int(b[b.startIndex + bd + 64]); let ns = Int(b[b.startIndex + bd + 65])
                    let nm = (0..<nameChars).map { i -> Character in
                        Character(UnicodeScalar(u16(b, bd+66+i*2))!) }
                    let nsName = ["POSIX","WIN32","DOS","WIN32&DOS"][min(ns,3)]
                    d += "      FILE_NAME name='\(String(nm))' ns=\(ns)(\(nsName)) file_attributes=0x\(String(u32(b, bd+56),radix:16)) alloc=\(u32(b,bd+40)) real=\(u32(b,bd+48)) reparse=0x\(String(u32(b,bd+60),radix:16))\n"
                    d += "      FILE_NAME full body hex: \(hex(bd, vlen))\n"
                }
            } else {
                d += "  @\(o) type=0x\(String(t,radix:16)) len=\(len) id=\(id) NONRES\n"
            }
            o += len
        }
        d += "  => \(fnCount) $FILE_NAME attribute(s) in this record\n"
        return d
    }

    func testNtfs3gReferenceFileNames() async throws {
        // small.img is authored by REAL ntfs-3g (scripts/make_test_images.sh:
        // mkntfs + ntfs-3g mount creating hello.txt, medium.txt, sub/, nested.txt).
        // Those are chkdsk-clean reference $FILE_NAME records.
        let here = URL(fileURLWithPath: #filePath)
        let imgPath = here.deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("small.img").path
        guard FileManager.default.fileExists(atPath: imgPath) else {
            throw XCTSkip("small.img fixture missing; run scripts/make_test_images.sh")
        }
        let dev = try FileHandleBlockDevice(openingFileAt: imgPath)
        let vol = try await Volume(device: dev)
        let mft = await vol.mft()

        var out = "\n\n########## ntfs-3g REFERENCE RECORDS (chkdsk-clean) ##########\n"
        let root = try await vol.enumerate(directory: 5)
        out += "root entries: \(root.map { "\($0.name)[rec \($0.recordNumber),ns \($0.fileName.namespace)]" }.joined(separator: ", "))\n\n"
        for entry in root where entry.recordNumber >= 16 {
            let rec = try await mft.record(at: entry.recordNumber)
            out += deepDump(rec.bytes, label: "ntfs-3g rec \(entry.recordNumber): \(entry.name)")
            // descend one level into directories
            if rec.isDirectory {
                if let kids = try? await vol.enumerate(directory: entry.recordNumber) {
                    for k in kids where k.recordNumber >= 16 {
                        let kr = try await mft.record(at: k.recordNumber)
                        out += deepDump(kr.bytes, label: "ntfs-3g rec \(k.recordNumber): \(entry.name)/\(k.name)")
                    }
                }
            }
        }

        // For contrast: what OUR builder produces for the same names (v3 path).
        out += "\n---------- OUR BUILDER (v3) for the same names ----------\n"
        for (name, isDir) in [("hello.txt", false), ("sub", true), ("nested.txt", false)] {
            let builder = MFTRecordBuilder(
                recordSize: 1024, sectorSize: 512, recordNumber: 40, sequenceNumber: 1,
                isDirectory: isDir, fileName: name, parentReference: (UInt64(1) << 48) | 5,
                securityID: 256, securityDescriptor: nil, dataRealSize: 0, dataAllocatedSize: 0)
            out += deepDump(try builder.build(), label: "OURS: \(name)")
        }
        print(out)
    }
}
