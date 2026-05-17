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
            print(padRight("RECNUM", 10) + padRight("SIZE", 12) + padRight("NAMESPACE", 12) + "NAME")
            for e in canonical {
                let typeMarker = e.isDirectory ? "/" : ""
                print(
                    padRight(String(e.recordNumber), 10) +
                    padRight(String(e.fileName.realSize), 12) +
                    padRight(String(describing: e.fileName.namespace), 12) +
                    e.name + typeMarker
                )
            }
        } else {
            for e in canonical {
                print(e.name + (e.isDirectory ? "/" : ""))
            }
        }
    }

    private func padRight(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s + " " }
        return s + String(repeating: " ", count: width - s.count)
    }
}
