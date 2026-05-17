import ArgumentParser
import Foundation
import NTFSCore

struct Cat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Print the contents of a file (by MFT record number or path) to stdout.",
        discussion: """
            Streams the file in fixed-size chunks (default 1 MiB) — no 1 GiB cap
            applies. For partial reads, pass --offset and --length.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "MFT record number of the file to read, OR a path under the volume root (e.g. /Backups/photo.jpg).")
    var target: String

    @Option(name: [.short, .long], help: "Byte offset to begin reading at. Default 0.")
    var offset: UInt64 = 0

    @Option(name: [.short, .long], help: "Maximum number of bytes to read. Default: read to EOF.")
    var length: UInt64?

    @Option(help: "Streaming chunk size in bytes. Default 1048576 (1 MiB).")
    var chunkSize: Int = 1 << 20

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
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

        var cursor = offset
        let bytesToRead: UInt64 = length ?? UInt64.max
        var written: UInt64 = 0
        while written < bytesToRead {
            let take = Int(min(UInt64(chunkSize), bytesToRead - written))
            let chunk = try await volume.readFileSlice(at: recordNumber, offset: cursor, length: take)
            if chunk.isEmpty { break }
            FileHandle.standardOutput.write(chunk)
            cursor += UInt64(chunk.count)
            written += UInt64(chunk.count)
            if chunk.count < take { break }  // EOF before reaching the requested chunk size
        }
    }
}
