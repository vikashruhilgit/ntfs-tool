import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import NTFSCore

/// Stress coverage for the "OOM on large `cp -r`" failure (repro 2026-06-28:
/// a 40 GB / 22,420-file copy was SIGKILL'd at ~27.68 GiB written).
///
/// Root cause was NOT the `$I30` B-tree (that path descends in O(log N) and
/// the existing `IndexAllocationGrowthTests` already drive 10k-entry inserts).
/// It was autorelease-pool accumulation on Darwin: every `FileHandle`
/// read/write hands back an autoreleased NSData buffer, and `ntfsctl cp`
/// runs as one long-lived async task with no pool drain, so each ~1 MiB
/// content chunk lived until process exit — RSS climbed to the full
/// transferred size. The fix drains the pool at the synchronous IO seams
/// (`FileHandleBlockDevice.readRange` / `writeRangeChunked`, and the host
/// read/write loops in the CLI / `writeFile`).
///
/// These tests assert (a) a large content copy completes correctly and
/// (b) the process's peak resident size grows by far less than the bytes
/// transferred — the property that was violated before the fix.
final class LargeCopyMemoryTests: XCTestCase {

    /// Format a fresh, empty NTFS image of `sizeMiB` and return its path.
    /// The image is created in the test bundle's temp dir and cleaned up via
    /// `addTeardownBlock`.
    private func makeFormattedImage(sizeMiB: Int) async throws -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("ntfsctl-largecopy-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = FileHandle(forWritingAtPath: path)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: path)
        let size = try await dev.size()
        try await Volume.formatNTFS(
            device: dev, deviceSizeBytes: size,
            label: "STRESS", volumeSerial: 0x0123_4567_89AB_CDEF
        )
        return path
    }

    /// Current resident set size of the test process, in bytes. `nil` if the
    /// platform can't report it (non-Darwin) so callers can skip cleanly.
    private func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : nil
        #else
        return nil
        #endif
    }

    // MARK: - Content-copy memory bound

    /// Copy a 1 MiB host file into the volume N times (distinct names) and
    /// assert the process's resident high-water grows by far less than the
    /// total bytes written. Before the autorelease fix, each 1 MiB chunk's
    /// NSData lived until process exit, so writing `N` MiB grew RSS by ~`N`
    /// MiB; the OOM killer fired once that crossed available memory. After the
    /// fix the per-chunk buffers drain at each IO call, so growth is flat.
    func testLargeContentCopyKeepsResidentMemoryBounded() async throws {
        guard let baseline = residentBytes() else {
            throw XCTSkip("resident-size reporting unavailable on this platform")
        }

        // 256 files × 1 MiB = 256 MiB pushed through the host-read +
        // device-write content path. Under the old leak this grew RSS by
        // ~256 MiB; the fix should keep it well under the bound below.
        let fileCount = 256
        let fileBytes = 1 << 20 // 1 MiB — matches the default cp chunk size.

        let imgPath = try await makeFormattedImage(sizeMiB: 512)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imgPath)
        let volume = try await Volume(device: device)

        // A single 1 MiB host source file, reused for every copy. Deterministic
        // bytes so the read-back sample can verify content integrity.
        let srcPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ntfsctl-largecopy-src-\(UUID().uuidString).bin")
        var payload = Data(count: fileBytes)
        for i in 0..<fileBytes { payload[i] = UInt8((i &* 31) & 0xFF) }
        try payload.write(to: URL(fileURLWithPath: srcPath))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: srcPath) }
        let srcURL = URL(fileURLWithPath: srcPath)

        let parentRN = try await volume.createFile(named: "bulk", inDirectory: 5, isDirectory: true)

        var peakGrowth: UInt64 = 0
        var sampledRecnum: UInt64 = 0
        try await volume.beginBulkInsert(into: parentRN)
        do {
            for i in 0..<fileCount {
                let name = String(format: "file-%05d.bin", i)
                let rn = try await volume.createFile(
                    named: name, inDirectory: parentRN,
                    isDirectory: false, dataSize: UInt64(fileBytes)
                )
                try await volume.writeFile(at: rn, fromFileAt: srcURL, chunkSize: fileBytes)
                if i == fileCount / 2 { sampledRecnum = rn }

                if let now = residentBytes() {
                    let growth = now > baseline ? now - baseline : 0
                    peakGrowth = max(peakGrowth, growth)
                }
            }
            _ = try await volume.endBulkInsert()
        } catch {
            _ = try? await volume.endBulkInsert()
            throw error
        }

        // Correctness: the directory holds every file and a sampled file's
        // bytes round-trip exactly.
        let entries = try await volume.enumerate(directory: parentRN)
            .filter { $0.fileName.namespace != .dos }
        XCTAssertEqual(entries.count, fileCount, "every copied file must be indexed in the parent $I30")
        let readBack = try await volume.readFile(at: sampledRecnum)
        XCTAssertEqual(readBack, payload, "sampled file content must round-trip byte-for-byte")

        // Memory bound: total content written is 256 MiB. The fix should keep
        // resident growth well under it; pre-fix it grew by ~the full amount.
        // 160 MiB is a deliberately generous ceiling (allocator slack, the
        // ~512 KiB index buffers, the $Bitmap copy) that still sits far below
        // the leaked 256 MiB, so it discriminates without flaking.
        let boundMiB: UInt64 = 160
        let peakMiB = peakGrowth / (1024 * 1024)
        XCTAssertLessThan(
            peakMiB, boundMiB,
            "resident high-water grew \(peakMiB) MiB writing \(fileCount) MiB of content — expected < \(boundMiB) MiB (autorelease leak regressed?)"
        )
    }

    // MARK: - Large single-directory index completion

    /// Create thousands of files in ONE directory and assert it completes and
    /// every entry is indexed. Guards the LARGE_INDEX insertion path against an
    /// O(N^2)/heavy regression — with the per-directory bulk leaf cache this is
    /// O(N log N) time and bounded memory (the cache is dropped at
    /// `endBulkInsert`). Count is overridable via NTFS_STRESS_FILES for an
    /// occasional 10k+ soak run; the default keeps the normal suite fast.
    func testLargeSingleDirectoryInsertCompletes() async throws {
        let target = Int(ProcessInfo.processInfo.environment["NTFS_STRESS_FILES"] ?? "4000") ?? 4000

        let imgPath = try await makeFormattedImage(sizeMiB: 256)
        let device = try FileHandleBlockDevice(openingFileForUpdateAt: imgPath)
        let volume = try await Volume(device: device)
        let parentRN = try await volume.createFile(named: "many", inDirectory: 5, isDirectory: true)

        try await volume.beginBulkInsert(into: parentRN)
        do {
            for i in 0..<target {
                _ = try await volume.createFile(named: String(format: "e-%06d.txt", i), inDirectory: parentRN)
            }
            _ = try await volume.endBulkInsert()
        } catch {
            _ = try? await volume.endBulkInsert()
            throw error
        }

        // Promotion to LARGE_INDEX must have happened well before `target`.
        let rec = try await volume.mft().record(at: parentRN)
        let attrs = try rec.attributes()
        XCTAssertTrue(
            attrs.contains { $0.type == .indexAllocation && $0.nameOrEmpty == "$I30" },
            "a \(target)-entry directory must be LARGE_INDEX (have $INDEX_ALLOCATION:$I30)"
        )

        // Every name is reachable both in-session and after a fresh reopen
        // (the on-disk B-tree, not a lucky in-memory cache).
        let names = Set(try await volume.enumerate(directory: parentRN)
            .filter { $0.fileName.namespace != .dos }
            .map { $0.name })
        XCTAssertEqual(names.count, target, "in-session enumeration must see all \(target) entries")

        let reopen = try await Volume(device: try FileHandleBlockDevice(openingFileAt: imgPath))
        let reopened = Set(try await reopen.enumerate(directory: parentRN)
            .filter { $0.fileName.namespace != .dos }
            .map { $0.name })
        XCTAssertEqual(reopened.count, target, "reopened enumeration must see all \(target) entries")
    }
}
