import ArgumentParser
import Foundation
import NTFSCore

/// Delete files or recursively delete directory trees on an NTFS volume.
/// Mirrors `rm` / `rm -r` semantics. Accepts paths (preferred) or MFT recnums.
struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove file(s) or directory tree(s) on an NTFS volume.",
        discussion: """
            Examples:
              # Remove one file by path:
              ntfsctl rm /dev/disk10s1 /Backups/draft.txt

              # Recursively remove a directory:
              ntfsctl rm -r /dev/disk10s1 /Backups/MyPhone

              # Remove by MFT recnum (legacy single-target):
              ntfsctl rm /dev/disk10s1 38
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "MFT recnum, OR a path under the volume root.")
    var target: String

    @Flag(name: [.short, .long], help: "Recursively remove directories.")
    var recursive: Bool = false

    @Flag(name: [.short, .long], help: "Print each entry as it is removed.")
    var verbose: Bool = false

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
        try await removeRecursive(volume: volume, rn: recordNumber)
        try await volume.setDirty(false)
    }

    private func removeRecursive(volume: NTFSCore.Volume, rn: UInt64) async throws {
        let mft = await volume.mft()
        let rec = try await mft.record(at: rn)
        if rec.isDirectory {
            if !recursive {
                throw ValidationError("\(target) is a directory; pass -r/--recursive to remove it")
            }
            let entries = try await volume.enumerate(directory: rn)
            for e in entries where e.fileName.namespace != .dos {
                try await removeRecursive(volume: volume, rn: e.recordNumber)
            }
        }
        try await volume.deleteFile(at: rn)
        if verbose {
            FileHandle.standardError.write(Data("rm recnum \(rn)\n".utf8))
        }
    }
}
