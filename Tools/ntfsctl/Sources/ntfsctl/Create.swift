import ArgumentParser
import Foundation
import NTFSCore

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new (empty) file or directory under a parent directory.",
        discussion: """
            Default parent is the volume root. Use --parent <path> to target a
            subdirectory (e.g. --parent /Backups). Use --parent-recnum N for
            the MFT-record-number form.

            Behavior change in v0.2: --parent now expects a PATH by default.
            Pass --parent-recnum for the legacy numeric form.

            Marks the volume dirty before the insert and clean (with fsync)
            after, so an interrupted run leaves Windows aware that chkdsk
            should scan the volume on next mount.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Name to give the new file.")
    var name: String

    @Option(name: [.short, .long], help: "Parent directory by path (default: /).")
    var parent: String = "/"

    @Option(name: .long, help: "Parent directory by MFT record number (overrides --parent).")
    var parentRecnum: UInt64?

    @Flag(name: [.short, .long], help: "Create as a directory rather than a file.")
    var directory: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let parentRN: UInt64
        if let n = parentRecnum {
            parentRN = n
        } else {
            guard let r = try await volume.resolvePath(parent) else {
                throw ValidationError("parent path not found: \(parent) (hint: try `ntfsctl list <device>` to see what exists; or pass --parent-recnum N)")
            }
            parentRN = r
        }
        try await volume.beginWriteSession()
        let recordNumber = try await volume.createFile(
            named: name,
            inDirectory: parentRN,
            isDirectory: directory
        )
        try await volume.endWriteSession()
        print("Created '\(name)' at MFT record \(recordNumber)\(directory ? " (directory)" : "")")
    }
}
