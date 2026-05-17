import ArgumentParser
import Foundation
import NTFSCore

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the contents of a directory on an NTFS volume."
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Argument(help: "MFT record number of the directory to list. 5 = root (default).")
    var recordNumber: UInt64 = 5

    @Flag(name: [.short, .long], help: "Long format (include size, namespace, parent ref).")
    var long: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let entries = try await volume.enumerate(directory: recordNumber)

        // Filter out DOS-namespace aliases so 8.3 names don't double up.
        let canonical = entries.filter { $0.fileName.namespace != .dos }

        if long {
            print(String(format: "%-10s %-12s %-12s %s", "RECNUM", "SIZE", "NAMESPACE", "NAME"))
            for e in canonical {
                let typeMarker = e.isDirectory ? "/" : ""
                print(String(
                    format: "%-10llu %-12llu %-12s %s%s",
                    e.recordNumber,
                    e.fileName.realSize,
                    "\(e.fileName.namespace)",
                    e.name,
                    typeMarker
                ))
            }
        } else {
            for e in canonical {
                print(e.name + (e.isDirectory ? "/" : ""))
            }
        }
    }
}
