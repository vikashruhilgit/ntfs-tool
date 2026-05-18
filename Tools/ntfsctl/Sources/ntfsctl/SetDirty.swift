import ArgumentParser
import Foundation
import NTFSCore

struct SetDirty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setdirty",
        abstract: "Set or clear the $VOLUME_INFORMATION dirty bit (manual escape hatch).",
        discussion: """
            Normal write commands (cp, write, rm, mv, create, delete, truncate)
            handle dirty-bit management automatically via beginWriteSession() /
            endWriteSession() — they mark the volume dirty before writing and
            clean (with fsync) when done. Use this command only to:
              - Force-clear dirty on a volume that something else left dirty.
              - Manually set dirty to test the chkdsk/ntfsfix path.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "1 = dirty (needs recovery), 0 = clean.")
    var value: Int

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        try await volume.setDirty(value != 0)
        try await blockDevice.synchronize()
        let nowDirty = try await volume.isDirty()
        print("$VOLUME_INFORMATION dirty bit set to \(nowDirty ? 1 : 0)")
    }
}
