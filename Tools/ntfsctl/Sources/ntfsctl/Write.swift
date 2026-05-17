import ArgumentParser
import Foundation
import NTFSCore

struct Write: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write file content to an existing file (by MFT record number or path).",
        discussion: """
            Two input modes:
              --from-file <path>: streams from a host file in 1 MiB chunks; no
                1 GiB cap applies. Use this for videos and other large files.
              (default): reads from stdin into memory, then writes. Practical
                ceiling is RSS — for multi-GB inputs prefer --from-file.

            The stdin path supports --offset 0 (rewrite) or --offset == file size
            (append). The --from-file path always rewrites from offset 0.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "MFT record number of the file to write to, OR a path under the volume root.")
    var target: String

    @Option(name: [.short, .long], help: "Offset to write at. 0 = rewrite, or pass the current file size to append. Default = 0. (Ignored for --from-file.)")
    var offset: UInt64 = 0

    @Option(name: .long, help: "Stream content from this host file path instead of stdin. Required for files larger than ~1 GiB.")
    var fromFile: String?

    @Option(help: "Streaming chunk size in bytes (only used with --from-file). Default 1048576 (1 MiB).")
    var chunkSize: Int = 1 << 20

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let recordNumber: UInt64
        if let parsed = UInt64(target) {
            recordNumber = parsed
        } else {
            guard let resolved = try await volume.resolvePath(target) else {
                throw ValidationError("path not found in volume: \(target)")
            }
            recordNumber = resolved
        }

        if let sourcePath = fromFile {
            let url = URL(fileURLWithPath: sourcePath)
            let size = try FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? UInt64 ?? 0
            try await volume.writeFile(at: recordNumber, fromFileAt: url, chunkSize: chunkSize)
            try await volume.setDirty(false)
            print("Streamed \(size) bytes from \(sourcePath) into MFT record \(recordNumber)")
        } else {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            try await volume.write(at: recordNumber, offset: offset, bytes: bytes)
            try await volume.setDirty(false)
            print("Wrote \(bytes.count) bytes to MFT record \(recordNumber) at offset \(offset)")
        }
    }
}
