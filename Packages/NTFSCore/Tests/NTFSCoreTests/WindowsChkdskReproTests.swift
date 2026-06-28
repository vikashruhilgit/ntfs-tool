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
}
