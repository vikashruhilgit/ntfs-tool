import ArgumentParser
import Foundation
import NTFSCore

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a file by MFT record number. Frees non-resident clusters via \\$Bitmap; bumps MFT sequence number for reuse."
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "MFT record number of the file to delete. Reserved records (0-15) are refused.")
    var recordNumber: UInt64

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        try await volume.deleteFile(at: recordNumber)
        print("Deleted MFT record \(recordNumber)")
    }
}
