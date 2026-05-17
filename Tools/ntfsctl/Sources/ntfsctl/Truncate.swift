import ArgumentParser
import Foundation
import NTFSCore

struct Truncate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "truncate",
        abstract: "Resize an existing file (by MFT record number). Stage 4: newSize = 0 OR cluster-aligned shrink only."
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "MFT record number of the file to truncate.")
    var recordNumber: UInt64

    @Argument(help: "New file size in bytes. 0 frees all clusters and resets $DATA to empty resident.")
    var newSize: UInt64

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        try await volume.truncate(at: recordNumber, newSize: newSize)
        print("Truncated MFT record \(recordNumber) to \(newSize) bytes")
    }
}
