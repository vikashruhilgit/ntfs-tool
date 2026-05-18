import ArgumentParser
import Foundation
import NTFSCore

/// Rename / move a file or directory on an NTFS volume. Removes the source's
/// $I30 entry from its current parent, updates $FILE_NAME with the new name
/// (and parent reference if moving), inserts a new $I30 entry under the
/// destination's parent.
struct Mv: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Rename or move a file/directory on an NTFS volume.",
        discussion: """
            Examples:
              # Simple rename in the same directory:
              ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

              # Move into a different directory (auto-creates parent if missing):
              ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Archive/final.txt

            Limitations:
              - Refuses to overwrite an existing destination.
              - The same LARGE_INDEX leaf-full cap applies to the destination
                parent's $I30.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Source path on the volume.")
    var source: String

    @Argument(help: "Destination path on the volume (rename target).")
    var destination: String

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        guard let srcRN = try await volume.resolvePath(source) else {
            throw ValidationError("source path not found: \(source)")
        }
        // Split destination into parent + leaf name.
        let trimmed = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)
        guard let leafName = components.last else {
            throw ValidationError("destination must include a final name component: \(destination)")
        }
        let parentComponents = Array(components.dropLast())
        var parentRN: UInt64 = 5
        for comp in parentComponents {
            let entries = try await volume.enumerate(directory: parentRN)
            if let match = entries.first(where: { $0.name.lowercased() == comp.lowercased() && $0.fileName.namespace != .dos }) {
                parentRN = match.recordNumber
            } else {
                // Auto-create intermediate directories.
                parentRN = try await volume.createFile(named: comp, inDirectory: parentRN, isDirectory: true)
            }
        }
        try await volume.beginWriteSession()
        try await volume.rename(at: srcRN, toName: leafName, inDirectory: parentRN)
        try await volume.endWriteSession()
        print("mv \(source) -> \(destination) (recnum \(srcRN))")
    }
}
