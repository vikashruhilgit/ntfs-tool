import ArgumentParser
import Foundation
import NTFSCore

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new (empty) file in MFT. Block-G-stage-3a: file is reachable by MFT record number but not yet visible in directory listings (Stage 3b wires up \\$I30)."
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Name to give the new file.")
    var name: String

    @Option(name: [.short, .long], help: "Parent directory's MFT record number. 5 = root (default).")
    var parent: UInt64 = 5

    @Flag(name: [.short, .long], help: "Create as a directory rather than a file.")
    var directory: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let recordNumber = try await volume.createFile(
            named: name,
            inDirectory: parent,
            isDirectory: directory
        )
        print("Created '\(name)' at MFT record \(recordNumber)\(directory ? " (directory)" : "")")
        print("Note: \\$I30 wiring lands in Stage 3b — the file is not yet visible to `list`.")
    }
}
