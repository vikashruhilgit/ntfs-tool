import ArgumentParser
import Foundation
import NTFSCore

struct SetDirty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setdirty",
        abstract: "Set or clear the $VOLUME_INFORMATION dirty bit. Clean (0) tells chkdsk/ntfsfix the volume was unmounted cleanly."
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Set the dirty bit: 1 = dirty (needs recovery), 0 = clean.")
    var value: Int

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        try await volume.setDirty(value != 0)
        let nowDirty = try await volume.isDirty()
        print("$VOLUME_INFORMATION dirty bit set to \(nowDirty ? 1 : 0)")
    }
}
