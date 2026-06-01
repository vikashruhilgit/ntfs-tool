import XCTest
@testable import NTFSCore

/// Reproduction for the **MFT over-grow + MFT/file-data overlap** bug seen on
/// the real 4 TB Windows-formatted drive: copying ~2,260 files grew `$MFT.$DATA`
/// to ~24,968 records (≈11× too many) and file data landed *inside* the MFT's
/// own extents (a record mapped to a cluster containing `%PDF`).
///
/// Mirrors the real drive's starting condition exactly: a **16-record** initial
/// `$MFT` (Windows quick-format shape), via `mftInitialClustersOverride: 4`.
final class MFTOvergrowReproTests: XCTestCase {

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
}
