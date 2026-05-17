import ArgumentParser
import Foundation
import NTFSCore

struct Cat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat",
        abstract: "Print the contents of a file (by MFT record number) to stdout."
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "MFT record number of the file to read.")
    var recordNumber: UInt64

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let content = try await volume.readFile(at: recordNumber)
        FileHandle.standardOutput.write(content)
    }
}
