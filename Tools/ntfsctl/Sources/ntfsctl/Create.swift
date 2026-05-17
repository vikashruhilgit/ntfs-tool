import ArgumentParser
import Foundation
import NTFSCore

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new (empty) file or directory. Inserts into the parent's \\$I30 so the file is visible to `list` immediately.",
        discussion: "Limitation: parent directory must have a resident-only \\$INDEX_ROOT (no \\$INDEX_ALLOCATION extension). LARGE_INDEX parents are rejected — that path lands in a future stage."
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
    }
}
