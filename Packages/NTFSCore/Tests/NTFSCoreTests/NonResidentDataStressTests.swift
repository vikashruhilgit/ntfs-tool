import XCTest
@testable import NTFSCore

/// Reproduces the real-Windows `chkdsk` failure where ~1,667 large files showed
/// "Attribute record (80, "") ... is corrupt" + some "attribute records ...
/// are unsorted" after a big `ntfsctl cp`. The trigger is SCALE: MFT growth
/// (tight MFT at a high LCN, like a real Windows volume) + many non-resident
/// files. This test writes that scenario to a file image and strictly
/// validates every record's $DATA / runlist / attribute ordering — the checks
/// chkdsk applies that our `verify` and macOS do not.
final class NonResidentDataStressTests: XCTestCase {

    private func u16(_ b: Data, _ o: Int) -> Int { Int(b[b.startIndex+o]) | (Int(b[b.startIndex+o+1])<<8) }
    private func u32(_ b: Data, _ o: Int) -> Int {
        Int(b[b.startIndex+o]) | (Int(b[b.startIndex+o+1])<<8) | (Int(b[b.startIndex+o+2])<<16) | (Int(b[b.startIndex+o+3])<<24)
    }
    private func u64(_ b: Data, _ o: Int) -> UInt64 {
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(b[b.startIndex+o+i]) << (8*i) }; return v
    }

    /// Decode an NTFS runlist; return (extentCount, totalClusters, bytesConsumed)
    /// or nil if malformed (bad header / runs past `limit`).
    private func decodeRunlist(_ b: Data, start: Int, limit: Int) -> (extents: Int, clusters: UInt64, end: Int)? {
        var o = start; var clusters: UInt64 = 0; var extents = 0
        while o < limit {
            let hdr = b[b.startIndex+o]
            if hdr == 0 { return (extents, clusters, o+1) }   // terminator
            let lenLen = Int(hdr & 0x0F); let offLen = Int((hdr >> 4) & 0x0F)
            if lenLen == 0 { return nil }                     // length field required
            o += 1
            if o + lenLen + offLen > limit { return nil }     // runs past attribute
            var len: UInt64 = 0; for i in 0..<lenLen { len |= UInt64(b[b.startIndex+o+i]) << (8*i) }
            clusters += len
            o += lenLen + offLen
            extents += 1
            if extents > 100000 { return nil }
        }
        return nil   // no terminator within limit
    }

    /// chkdsk-style validation of one record. Returns list of problems.
    private func validate(_ b: Data, rn: UInt64) -> [String] {
        var p: [String] = []
        if u32(b,0) != 0x454C4946 { return p }   // not FILE (free slot) — skip
        let firstAttr = u16(b,20), used = u32(b,24), alloc = u32(b,28)
        let nextID = u16(b,40)
        var o = firstAttr, prevType = -1, maxID = -1, guardN = 0
        var seenIDs = Set<Int>()
        while o + 4 <= alloc {
            guardN += 1; if guardN > 200 { p.append("rec \(rn): attr walk runaway"); break }
            let t = u32(b,o)
            if t == 0xFFFFFFFF { break }
            if o + 16 > alloc { p.append("rec \(rn): attr hdr @\(o) past record"); break }
            let len = u32(b,o+4)
            if len < 16 || len % 8 != 0 { p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) bad len \(len)"); break }
            if o + len > used { p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) end \(o+len) > used_size \(used)") }
            if t < prevType { p.append("rec \(rn): UNSORTED — attr 0x\(String(t,radix:16)) @\(o) after 0x\(String(prevType,radix:16))") }
            prevType = t
            let id = u16(b,o+14)
            if seenIDs.contains(id) { p.append("rec \(rn): dup instance id \(id)") }
            seenIDs.insert(id); maxID = max(maxID,id)
            let nonres = b[b.startIndex+o+8]
            if nonres == 0 {
                let vlen = u32(b,o+16), voff = u16(b,o+20)
                if voff + vlen > len { p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) resident value (off \(voff)+len \(vlen)) > attrLen \(len)") }
            } else {
                // Non-resident: validate runlist fits inside the attribute.
                let runOff = u16(b,o+32)
                let evcn = u64(b,o+24), svcn = u64(b,o+16)
                let alloc8 = u64(b,o+40)
                if runOff < 64 || runOff > len { p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) bad runOff \(runOff) (len \(len))") }
                else if let rl = decodeRunlist(b, start: o+runOff, limit: o+len) {
                    let expectedClusters = evcn &- svcn &+ 1
                    if rl.clusters != expectedClusters {
                        p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) runlist clusters \(rl.clusters) != eVCN-sVCN+1 \(expectedClusters)")
                    }
                    // allocatedSize should match runlist clusters * clusterBytes (4096).
                    if alloc8 != rl.clusters &* 4096 {
                        p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) alloc \(alloc8) != runlistClusters*4096 \(rl.clusters &* 4096)")
                    }
                } else {
                    p.append("rec \(rn): attr 0x\(String(t,radix:16)) @\(o) MALFORMED RUNLIST (runs past attribute / no terminator)")
                }
            }
            o += len
        }
        if nextID <= maxID { p.append("rec \(rn): nextAttrID \(nextID) <= maxID \(maxID)") }
        return p
    }

    /// Heavy fragmentation → large files get many-extent runlists that can
    /// overflow the base MFT record (→ $ATTRIBUTE_LIST migration). This is the
    /// suspected source of the real-drive "Attribute record (80) is corrupt" +
    /// "unsorted" errors. Reports the worst extent counts so we can see whether
    /// migration fired.
    func testFragmentedLargeFileRunlists() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("frag-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: tmp, contents: nil)
        let h = FileHandle(forWritingAtPath: tmp)!
        try h.truncate(atOffset: 96 * 1024 * 1024)   // 96 MiB
        try h.close()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "FRAG",
                                        volumeSerial: 0xF7A6,
                                        mftInitialClustersOverride: 4, mftStartLCNOverride: 8192)
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5
        let oneCluster = Data(repeating: 0xAB, count: 4096)

        // 1. Fill with single-cluster files to pack the volume.
        var fillers: [UInt64] = []
        for i in 0..<3000 {
            do {
                let rn = try await vol.createFile(named: "f\(i)", inDirectory: root, isDirectory: false, dataSize: 4096)
                var p: Data? = oneCluster
                try await vol.writeFile(at: rn, totalSize: 4096) { defer { p = nil }; return p ?? Data() }
                fillers.append(rn)
            } catch { break }   // out of space — fine
        }
        // 2. Delete every other → 1-cluster holes scattered across the volume.
        for (i, rn) in fillers.enumerated() where i % 2 == 0 {
            try? await vol.deleteFile(at: rn)
        }
        // 3. Write large files that must fragment into the scattered holes.
        var bigFiles: [UInt64] = []
        let big = Data(repeating: 0xCD, count: 200 * 4096)   // 200 clusters
        for i in 0..<6 {
            do {
                let rn = try await vol.createFile(named: "big\(i).bin", inDirectory: root, isDirectory: false, dataSize: UInt64(big.count))
                var p: Data? = big
                try await vol.writeFile(at: rn, totalSize: UInt64(big.count)) { defer { p = nil }; return p ?? Data() }
                bigFiles.append(rn)
            } catch let e { print("big\(i) write failed: \(e)") }
        }

        let mft = await vol.mft()
        var problems: [String] = []
        var maxExtents = 0
        for rn in bigFiles {
            let rec = try await mft.record(at: rn)
            let b = rec.bytes
            // count $DATA extents + check for $ATTRIBUTE_LIST (0x20)
            var o = u16(b,20); var hasAttrList = false
            while o + 4 <= b.count {
                let t = u32(b,o); if t == 0xFFFFFFFF { break }
                let l = u32(b,o+4); if l == 0 { break }
                if t == 0x20 { hasAttrList = true }
                if t == 0x80 && b[b.startIndex+o+8] != 0 {
                    let runOff = u16(b,o+32)
                    if let rl = decodeRunlist(b, start: o+runOff, limit: o+l) { maxExtents = max(maxExtents, rl.extents) }
                }
                o += l
            }
            problems.append(contentsOf: validate(b, rn: rn))
            if hasAttrList { print("rec \(rn): has $ATTRIBUTE_LIST (migration fired)") }
        }
        print("FRAG: fillers=\(fillers.count) bigFiles=\(bigFiles.count) maxDataExtents=\(maxExtents) problems=\(problems.count)")
        for p in problems.prefix(40) { print("   ❌ \(p)") }
        XCTAssertTrue(problems.isEmpty, "fragmented non-resident $DATA corruption:\n" + problems.prefix(40).joined(separator: "\n"))
    }

    /// Perf regression: on a volume with a LARGE cluster bitmap (a big drive),
    /// writing files must stay ~O(1) per file. The old allocator (a) rescanned
    /// the $MFT bitmap from the start each createFile — O(N^2) — and (b) made a
    /// copy-on-write clone of the whole ~tens-of-MB cluster bitmap per file.
    /// Together that caused the ~82-min / OOM behavior on a 4 TB `cp -r`. This
    /// uses a 256 GiB SPARSE image (bitmap ~8 MiB) and asserts the second half
    /// of the run isn't dramatically slower than the first (no super-linear
    /// growth). A regression that reintroduces the clone/rescan blows the bound.
    func testAllocatorStaysLinearOnLargeBitmap() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: tmp, contents: nil)
        let h = FileHandle(forWritingAtPath: tmp)!
        try h.truncate(atOffset: 256 * 1024 * 1024 * 1024)   // 256 GiB sparse (bitmap ~8 MiB)
        try h.close()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "PERF",
                                        volumeSerial: 0x9E9F,
                                        mftInitialClustersOverride: 4, mftStartLCNOverride: 200000)
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5
        let payload = Data(repeating: 0x5A, count: 40 * 1024)   // non-resident
        let N = 2000
        func writeBatch(_ range: Range<Int>) async throws -> TimeInterval {
            let t0 = Date()
            for i in range {
                let rn = try await vol.createFile(named: "p_\(i).bin", inDirectory: root, isDirectory: false, dataSize: UInt64(payload.count))
                var p: Data? = payload
                try await vol.writeFile(at: rn, totalSize: UInt64(payload.count)) { defer { p = nil }; return p ?? Data() }
            }
            return Date().timeIntervalSince(t0)
        }
        let firstHalf = try await writeBatch(0..<(N/2))
        let secondHalf = try await writeBatch((N/2)..<N)
        print("PERF: large-bitmap volume, \(N) files. firstHalf=\(String(format: "%.2f", firstHalf))s secondHalf=\(String(format: "%.2f", secondHalf))s ratio=\(String(format: "%.2f", secondHalf/max(firstHalf,0.001)))")
        // O(N^2) would make the second half ~3x the first (it's at 2-3x the
        // record count). Allow generous slack for timing noise but catch a real
        // super-linear regression.
        XCTAssertLessThan(secondHalf, firstHalf * 3.0,
            "allocator went super-linear: secondHalf \(secondHalf)s vs firstHalf \(firstHalf)s — the O(N^2) MFT rescan or per-file bitmap clone is back")
    }

    func testManyNonResidentFilesWithMFTGrowth() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nrstress-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: tmp, contents: nil)
        let h = FileHandle(forWritingAtPath: tmp)!
        try h.truncate(atOffset: 512 * 1024 * 1024)   // 512 MiB
        try h.close()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Windows-like layout: tight MFT (16 records) placed at a high LCN, so
        // the very first user files force MFT growth — the scale condition.
        do {
            let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
            let size = try await dev.size()
            try await Volume.formatNTFS(device: dev, deviceSizeBytes: size, label: "NRSTRESS",
                                        volumeSerial: 0xCAFE,
                                        mftInitialClustersOverride: 4,        // 16 records → grow immediately
                                        mftStartLCNOverride: 16384)           // MFT at 64 MiB, like Windows
        }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: tmp)
        let vol = try await Volume(device: dev)
        let root: UInt64 = 5

        // Write enough non-resident files to grow the MFT well past 16 records.
        // Each ~40 KiB (11 clusters) → non-resident. 400 files → MFT ~ 400+ recs.
        let payload = Data(repeating: 0x5A, count: 40 * 1024)
        var created: [UInt64] = []
        for i in 0..<400 {
            let rn = try await vol.createFile(named: "file_\(i).bin", inDirectory: root,
                                              isDirectory: false, dataSize: UInt64(payload.count))
            var pending: Data? = payload
            try await vol.writeFile(at: rn, totalSize: UInt64(payload.count)) { defer { pending = nil }; return pending ?? Data() }
            created.append(rn)
        }

        // Validate EVERY user record's structure (chkdsk-style).
        let mft = await vol.mft()
        var problems: [String] = []
        var nonResChecked = 0
        for rn in created {
            let rec = try await mft.record(at: rn)
            let probs = validate(rec.bytes, rn: rn)
            if rec.bytes.contains(where: { _ in false }) {} // no-op
            // count non-resident
            if (try? rec.attributes())?.contains(where: { $0.type == .data && { if case .nonResident = $0.value { return true } else { return false } }($0) }) == true {
                nonResChecked += 1
            }
            problems.append(contentsOf: probs)
        }
        print("STRESS: wrote \(created.count) files, non-resident \(nonResChecked), problems \(problems.count)")
        for p in problems.prefix(40) { print("   ❌ \(p)") }
        XCTAssertTrue(problems.isEmpty, "non-resident $DATA / attribute corruption reproduced:\n" + problems.prefix(40).joined(separator: "\n"))
    }
}
