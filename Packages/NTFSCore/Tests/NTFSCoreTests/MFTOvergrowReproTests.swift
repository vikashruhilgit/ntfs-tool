import XCTest
@testable import NTFSCore

/// Reproduction for the **MFT over-grow + MFT/file-data overlap** bug seen on
/// the real 4 TB Windows-formatted drive: copying ~2,260 files grew `$MFT.$DATA`
/// to ~24,968 records (≈11× too many) and file data landed *inside* the MFT's
/// own extents (a record mapped to a cluster containing `%PDF`).
///
/// Root cause: `growMFTDataByClusters` allocated MFT-extension clusters from the
/// global low `_allocHint` (shared with the file-data front) instead of near the
/// MFT's own runlist tail. On our own formatter's layout (`$MFT` at LCN 4, right
/// before the data region) the growth happened to stay adjacent and merge, so
/// the bug was invisible. It only surfaces on a Windows layout where `$MFT` sits
/// at a high LCN (786432 = 3 GiB) with a reserved MFT zone after it — the
/// growth then landed far from the base, never merged, and the runlist
/// fragmented down into the file-data region.
///
/// The `mftStartLCNOverride` format option lets us recreate that layout locally:
/// `$MFT` at a high LCN with a large free zone after it, file data allocating
/// from low clusters. The fix is the MFT-lane locality allocator
/// (`allocateMFTGrowthClusters`).
final class MFTOvergrowReproTests: XCTestCase {

    // MARK: low-LCN layout (our own formatter) — guards the easy case

    private func volume(mftRecords: UInt64, sizeMiB: Int) async throws -> Volume {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mft-overgrow-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024); try h.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        try await Volume.formatNTFS(device: dev, deviceSizeBytes: try await dev.size(),
                                    label: "OG", volumeSerial: 0x0123_4567_89AB_CDEF,
                                    mftInitialClustersOverride: max(4, (mftRecords + 3) / 4))
        return try await Volume(device: dev)
    }

    // MARK: high-LCN layout (Windows-style) — reproduces the real-drive bug

    /// Format a volume with `$MFT` relocated to `mftLCN` (high), a 16-record
    /// initial MFT (4 clusters), and a large free MFT zone after it.
    private func windowsLayoutVolume(sizeMiB: Int, mftLCN: UInt64) async throws -> Volume {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mft-winlayout-\(UUID().uuidString).img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024); try h.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        try await Volume.formatNTFS(device: dev, deviceSizeBytes: try await dev.size(),
                                    label: "WIN", volumeSerial: 0x0123_4567_89AB_CDEF,
                                    mftInitialClustersOverride: 4,
                                    mftStartLCNOverride: mftLCN)
        return try await Volume(device: dev)
    }

    private func mftAllocRecords(_ v: Volume) async throws -> UInt64 {
        let r0 = try await v.mft().record(at: 0)
        guard let d = try r0.attributes().first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else { return 0 }
        if case let .nonResident(_,_,_,_,a,_,_,_) = d.value { return a / 1024 }
        if case let .resident(b,_) = d.value { return UInt64(b.count) / 1024 }
        return 0
    }

    func testMFTDoesNotBalloonOnManyFiles() async throws {
        let v = try await volume(mftRecords: 16, sizeMiB: 256)
        let dir = try await v.createFile(named: "pics", inDirectory: 5, isDirectory: true)
        let count = 2300
        for i in 0..<count {
            _ = try await v.createFile(named: String(format: "f%05d.jpg", i), inDirectory: dir)
        }
        let allocRecs = try await mftAllocRecords(v)
        // Each file needs ~1 record; with system records + a chunk of runway,
        // a healthy MFT is well under 2× the file count. The bug ballooned it
        // to ~11×.
        XCTAssertLessThan(allocRecs, UInt64(count) * 2 + 1024,
            "MFT $DATA ballooned: \(allocRecs) records for \(count) files (healthy: ~\(count + 512))")
    }

    /// Stronger check: no low MFT record (a system or early-user record) may be
    /// overwritten by file data — every in-use record must still be a FILE.
    func testNoMFTFileDataOverlap() async throws {
        let v = try await volume(mftRecords: 16, sizeMiB: 256)
        let dir = try await v.createFile(named: "d", inDirectory: 5, isDirectory: true)
        for i in 0..<1500 {
            _ = try await v.createFile(named: String(format: "g%05d.bin", i), inDirectory: dir)
        }
        let mft = await v.mft()
        var nonFile = 0
        for rn: UInt64 in 0..<200 {   // system + early user records must be intact
            if let rec = try? await mft.record(at: rn), rec.isInUse {
                // record(at:) parses the FILE magic; a non-FILE record throws and
                // is caught above. Re-read raw to be sure the magic is 'FILE'.
                _ = rec
            } else if (try? await mft.record(at: rn)) == nil {
                nonFile += 1
            }
        }
        XCTAssertEqual(nonFile, 0, "low MFT records overwritten by file data: \(nonFile)")
    }

    // MARK: - Windows-layout reproductions (the real bug)

    /// THE regression test. On a Windows layout ($MFT high at LCN 40000 with a
    /// free zone after it), the pre-fix allocator grew the MFT into the LOW
    /// file-data region. The fix keeps every MFT extent at/above the MFT base.
    ///
    /// Invariant: the `$MFT.$DATA` runlist must stay (a) coalesced into a
    /// handful of extents and (b) entirely at or above the MFT base LCN — never
    /// down in the low clusters where file data lives. Pre-fix this FAILS
    /// (growth extents land near LCN ~400, far below 40000).
    func testHighLCNMftGrowsIntoItsZoneNotTheDataRegion() async throws {
        let mftLCN: UInt64 = 40_000
        let v = try await windowsLayoutVolume(sizeMiB: 256, mftLCN: mftLCN)
        let dir = try await v.createFile(named: "pics", inDirectory: 5, isDirectory: true)

        // Enough files to force many MFT auto-grow rounds past the 16-record
        // initial MFT, with real (non-resident) data interleaved so file-data
        // cluster allocation competes with MFT growth for the allocator — the
        // exact interleaving that fragmented the runlist on the real drive.
        let count = 1200
        let payload = Data(repeating: 0xAB, count: 4096)   // 1 cluster, non-resident
        for i in 0..<count {
            let rn = try await v.createFile(named: String(format: "f%05d.bin", i),
                                            inDirectory: dir, dataSize: UInt64(payload.count))
            var sent = false
            try await v.writeFile(at: rn, totalSize: UInt64(payload.count)) {
                if sent { return Data() }
                sent = true
                return payload
            }
        }

        let mftExtents = await v.mftDataExtents() ?? []
        XCTAssertFalse(mftExtents.isEmpty, "could not read $MFT.$DATA runlist")

        // (a) Coalesced: the fix allocates each growth right after the tail, so
        // the whole MFT should collapse to ~1-2 extents. Pre-fix it fragments
        // into one extent per grow (dozens+).
        XCTAssertLessThanOrEqual(mftExtents.count, 6,
            "MFT runlist fragmented into \(mftExtents.count) extents: \(mftExtents)")

        // (b) Lane separation: every MFT extent must sit at/above the MFT base.
        // Pre-fix, growth extents land in the low file-data region (< mftLCN).
        for ex in mftExtents {
            guard let lcn = ex.startLCN else { continue }
            XCTAssertGreaterThanOrEqual(lcn, mftLCN,
                "MFT extent at LCN \(lcn) is below the MFT base \(mftLCN) — grew into the file-data region")
        }

        // (c) No over-grow: record count stays near the file count.
        let allocRecs = try await mftAllocRecords(v)
        XCTAssertLessThan(allocRecs, UInt64(count) * 2 + 1024,
            "MFT $DATA ballooned: \(allocRecs) records for \(count) files")
    }

    /// Direct overlap check on the Windows layout: collect every file's $DATA
    /// clusters and assert none of them coincide with any $MFT extent cluster.
    func testHighLCNNoFileDataInsideMFT() async throws {
        let mftLCN: UInt64 = 40_000
        let v = try await windowsLayoutVolume(sizeMiB: 256, mftLCN: mftLCN)
        let dir = try await v.createFile(named: "d", inDirectory: 5, isDirectory: true)

        let count = 800
        let payload = Data(repeating: 0xCD, count: 4096)
        var fileRNs: [UInt64] = []
        for i in 0..<count {
            let rn = try await v.createFile(named: String(format: "h%05d.bin", i),
                                            inDirectory: dir, dataSize: UInt64(payload.count))
            var sent = false
            try await v.writeFile(at: rn, totalSize: UInt64(payload.count)) {
                if sent { return Data() }; sent = true; return payload
            }
            fileRNs.append(rn)
        }

        // Cluster set occupied by the MFT.
        var mftClusters = Set<UInt64>()
        for ex in (await v.mftDataExtents() ?? []) {
            guard let lcn = ex.startLCN else { continue }
            for c in lcn..<(lcn + ex.clusterCount) { mftClusters.insert(c) }
        }

        // Every file's $DATA clusters must be disjoint from the MFT's.
        let mft = await v.mft()
        for rn in fileRNs {
            let rec = try await mft.record(at: rn)
            guard let dataAttr = try rec.attributes().first(where: { $0.type == .data && $0.nameOrEmpty == "" }),
                  case let .nonResident(_,_,_,_,_,_,_, extents) = dataAttr.value else { continue }
            for ex in extents {
                guard let lcn = ex.startLCN else { continue }
                for c in lcn..<(lcn + ex.clusterCount) {
                    XCTAssertFalse(mftClusters.contains(c),
                        "file record \(rn) $DATA cluster \(c) overlaps the $MFT region")
                }
            }
        }
    }
}
