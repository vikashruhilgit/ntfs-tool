import XCTest
@testable import NTFSCore

/// Emits a `Volume.formatNTFS` image to a fixed path so external oracles
/// (real ntfs-3g / mkntfs in Docker, Windows chkdsk) can judge it. Only runs
/// when NTFS_EMIT_PATH is set, so it is inert in the normal suite.
///   NTFS_EMIT_PATH=/tmp/fmt.img NTFS_EMIT_MIB=64 swift test \
///       --package-path Packages/NTFSCore --filter FormatEmitTests
final class FormatEmitTests: XCTestCase {
    func testEmitFormattedImage() async throws {
        guard let outPath = ProcessInfo.processInfo.environment["NTFS_EMIT_PATH"] else {
            throw XCTSkip("set NTFS_EMIT_PATH to emit a formatted image")
        }
        let sizeMiB = Int(ProcessInfo.processInfo.environment["NTFS_EMIT_MIB"] ?? "64") ?? 64
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let h = FileHandle(forWritingAtPath: outPath)!
        try h.truncate(atOffset: UInt64(sizeMiB) * 1024 * 1024)
        try h.close()

        let dev = try FileHandleBlockDevice(openingFileForUpdateAt: outPath)
        let size = try await dev.size()
        try await Volume.formatNTFS(device: dev, deviceSizeBytes: size,
                                    label: "NTFSCTLFMT", volumeSerial: 0x0123_4567_89AB_CDEF)
        // Re-open + parse a few system records as a self-check.
        let vol = try await Volume(device: dev)
        let mft = await vol.mft()
        for rn in UInt64(0)...11 { _ = try await mft.record(at: rn) }
        print("EMITTED formatted image: \(outPath) (\(sizeMiB) MiB)")
    }
}
