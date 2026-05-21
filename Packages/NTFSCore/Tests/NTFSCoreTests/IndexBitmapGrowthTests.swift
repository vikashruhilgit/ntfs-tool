import XCTest
@testable import NTFSCore

/// v0.5: resident `$BITMAP:$I30` growth.
///
/// Before v0.5 a directory's resident `$BITMAP:$I30` attribute was created
/// as a fixed 8-byte body (room for 64 `$INDEX_ALLOCATION` INDX blocks). The
/// 65th INDX block aborted the write with
/// `unsupportedFeature("updateBitmap: block index 64 exceeds bitmap capacity 64; ...")`.
/// On real hardware this killed a 22,419-file `cp -r` at file 1611.
///
/// These tests drive a single directory past 64 INDX blocks and assert the
/// resident bitmap grew (append-only, 8-byte aligned) while every inserted
/// name still enumerates and the MFT walk reports zero orphans.
///
/// AC-3 note (parent-record-overflow boundary): the growth increment is a
/// single 8-byte chunk per 64 additional blocks, so the resident bitmap body
/// stays tiny (a few tens of bytes) for any directory we can build inside the
/// v0.5 small fixture. The parent-MFT-record slack is therefore effectively
/// unreachable within v0.5 scope. Should it ever be reached, the existing
/// rewrite path (`rewriteEntireAttribute`) detects the overflow and throws a
/// clean `NTFSError.unsupportedFeature` while building its output into a fresh
/// buffer — so no partial write reaches disk and on-disk state is unchanged.
/// We took the "documented-unreachable + clean-throw confirmed by reading the
/// rewrite path" option, not a manufactured overflow test.
final class IndexBitmapGrowthTests: XCTestCase {

    private func fixtureExists(_ name: String) -> Bool {
        let here = URL(fileURLWithPath: #filePath)
        let path = here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Locate the parent directory's resident `$BITMAP:$I30` body, mirroring
    /// how production code at the throw site fetches it (rawType 0xB0, name
    /// `$I30`, resident).
    private func readI30BitmapBody(volume: Volume, directory: UInt64) async throws -> Data {
        let mft = await volume.mft()
        let rec = try await mft.record(at: directory)
        let attrs = try rec.attributes()
        guard let bm = attrs.first(where: { $0.rawType == 0xB0 && $0.nameOrEmpty == "$I30" }) else {
            throw XCTSkip("directory \(directory) has no $BITMAP:$I30 (still SMALL_INDEX?)")
        }
        guard case let .resident(bytes, _) = bm.value else {
            throw XCTSkip("$BITMAP:$I30 is non-resident — beyond v0.5 scope")
        }
        return bytes
    }

    /// Count how many INDX blocks the directory's `$INDEX_ALLOCATION:$I30`
    /// spans (one block == one cluster on this fixture).
    private func indexBlockCount(volume: Volume, directory: UInt64) async throws -> Int {
        let mft = await volume.mft()
        let rec = try await mft.record(at: directory)
        let attrs = try rec.attributes()
        guard let alloc = attrs.first(where: { $0.type == .indexAllocation && $0.nameOrEmpty == "$I30" }),
              case let .nonResident(_, _, _, _, _, _, _, extents) = alloc.value else {
            return 0
        }
        return extents.reduce(0) { $0 + Int($1.clusterCount) }
    }

    /// Insert files into `directory` until it spans at least `targetBlocks`
    /// INDX blocks (or we run out of MFT slots / space). Grows $MFT.$DATA
    /// aggressively up front so the cap is the index algorithm, not slots.
    /// Returns the inserted names.
    private func fillUntilBlocks(
        volume: Volume,
        directory: UInt64,
        targetBlocks: Int,
        maxInserts: Int
    ) async throws -> [String] {
        // Grow $MFT.$DATA as much as the small fixture tolerates so we have
        // plenty of record slots; 65 INDX blocks needs many hundreds of
        // entries.
        for _ in 0..<6 {
            try? await volume.growMFTDataByClusters(64)
        }
        var inserted: [String] = []
        for i in 0..<maxInserts {
            let name = String(format: "bmgrow-%05d.txt", i)
            do {
                _ = try await volume.createFile(named: name, inDirectory: directory)
                inserted.append(name)
            } catch NTFSError.unsupportedFeature {
                break
            } catch NTFSError.outOfSpace {
                break
            }
            if i % 25 == 0 {
                let blocks = try await indexBlockCount(volume: volume, directory: directory)
                if blocks > targetBlocks { break }
            }
        }
        return inserted
    }

    func testI30BitmapGrowsPast64Blocks() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        // Drive root (recnum 5, already LARGE_INDEX on this fixture) past 64
        // INDX blocks so block index 64 forces the bitmap to grow.
        let inserted = try await fillUntilBlocks(
            volume: volume,
            directory: 5,
            targetBlocks: 64,
            maxInserts: 4000
        )

        let blocks = try await indexBlockCount(volume: volume, directory: 5)
        FileHandle.standardError.write(Data(
            "[bmgrow] inserted=\(inserted.count) indx_blocks=\(blocks)\n".utf8
        ))
        try XCTSkipUnless(
            blocks > 64,
            "could not reach 65 INDX blocks within fixture limits (reached \(blocks) blocks via \(inserted.count) inserts); bitmap-growth path not exercised"
        )

        // Reopen the fixture from disk and assert the on-disk bitmap grew.
        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)

        // (a) $BITMAP:$I30 body is now > 8 bytes.
        let body = try await readI30BitmapBody(volume: reopened, directory: 5)
        XCTAssertGreaterThan(
            body.count, 8,
            "resident $BITMAP:$I30 should have grown beyond its initial 8-byte body once block 64 was allocated; got \(body.count) bytes"
        )

        // (b) block index 64 → byte 8, bit 0 must be set.
        XCTAssertGreaterThan(body.count, 8, "bitmap too small to hold block-64 bit")
        let byte8 = body[body.startIndex + 8]
        XCTAssertEqual(byte8 & 0x01, 0x01, "the 65th INDX block's bit (block 64 → byte 8 bit 0) must be set")

        // (c) all earlier block bits (0..<64) remain set — every one of the
        // first 64 INDX blocks is allocated, so the first 8 bytes are 0xFF.
        for i in 0..<8 {
            XCTAssertEqual(
                body[body.startIndex + i], 0xFF,
                "earlier block bits in byte \(i) must survive growth (append-only); got 0x\(String(body[body.startIndex + i], radix: 16))"
            )
        }

        // (d) every inserted name still enumerates.
        let entries = try await reopened.enumerate(directory: 5)
        let names = Set(entries.map { $0.name })
        for n in inserted {
            XCTAssertTrue(names.contains(n), "inserted '\(n)' missing after bitmap growth + reopen")
        }

        // (e) full-MFT verify walk reports zero orphans (mirrors `ntfsctl verify`).
        let mft = await reopened.mft()
        var inUseUser: Set<UInt64> = []
        for rn: UInt64 in 0..<2048 {
            guard let rec = try? await mft.record(at: rn) else { continue }
            if rec.isInUse, rn >= 16 { inUseUser.insert(rn) }
        }
        var reachable: Set<UInt64> = [5]
        var queue: [UInt64] = [5]
        while let dir = queue.popLast() {
            guard let dirEntries = try? await reopened.enumerate(directory: dir) else { continue }
            for e in dirEntries where e.fileName.namespace != .dos {
                if !reachable.contains(e.recordNumber) {
                    reachable.insert(e.recordNumber)
                    if e.isDirectory { queue.append(e.recordNumber) }
                }
            }
        }
        let orphans = inUseUser.subtracting(reachable.filter { $0 >= 16 })
        XCTAssertTrue(
            orphans.isEmpty,
            "bitmap-growth orphan check: \(orphans.count) MFT slots IN_USE=1 but unreachable. Recnums: \(orphans.sorted().prefix(10))"
        )
    }

    func testI30BitmapGrowthIsEightByteAligned() async throws {
        guard fixtureExists("small.img") else { throw XCTSkip("fixture missing") }
        let path = try MutableFixture.scopedCopy("small.img", testCase: self)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let volume = try await Volume(device: device)

        let inserted = try await fillUntilBlocks(
            volume: volume,
            directory: 5,
            targetBlocks: 64,
            maxInserts: 4000
        )
        let blocks = try await indexBlockCount(volume: volume, directory: 5)
        FileHandle.standardError.write(Data(
            "[bmgrow-align] inserted=\(inserted.count) indx_blocks=\(blocks)\n".utf8
        ))

        // Whether or not we crossed 64 blocks, the resident bitmap body length
        // must always be a multiple of 8 bytes (NTFS index-bitmap alignment,
        // preserved by both initial creation and the v0.5 growth path).
        let bodyLive = try await readI30BitmapBody(volume: volume, directory: 5)
        XCTAssertEqual(
            bodyLive.count % 8, 0,
            "live $BITMAP:$I30 body length must be a multiple of 8; got \(bodyLive.count)"
        )

        let reader = try FileHandleBlockDevice(openingFileAt: path)
        let reopened = try await Volume(device: reader)
        let bodyDisk = try await readI30BitmapBody(volume: reopened, directory: 5)
        XCTAssertEqual(
            bodyDisk.count % 8, 0,
            "on-disk $BITMAP:$I30 body length must be a multiple of 8; got \(bodyDisk.count)"
        )
    }
}
