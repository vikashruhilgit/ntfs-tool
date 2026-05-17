import ArgumentParser
import Foundation
import NTFSCore

struct Write: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write file content to an existing file (by MFT record number). Reads bytes from stdin.",
        discussion: """
            Stage 4: rewrites file content from offset 0, or appends (offset must equal current size).
            Partial overwrites at arbitrary middle offsets land in Stage 4b.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "MFT record number of the file to write to.")
    var recordNumber: UInt64

    @Option(name: [.short, .long], help: "Offset to write at. 0 = rewrite, or pass the current file size to append. Default = 0.")
    var offset: UInt64 = 0

    func run() async throws {
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        try await volume.write(at: recordNumber, offset: offset, bytes: bytes)
        print("Wrote \(bytes.count) bytes to MFT record \(recordNumber) at offset \(offset)")
    }
}
