import ArgumentParser
import Foundation
import NTFSCore

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one file (low-level: by path or recnum). For directory trees use `rm -r`.",
        discussion: """
            Removes a single file: frees non-resident clusters via $Bitmap,
            removes the $I30 entry from the parent, bumps the MFT sequence
            number for reuse. Refuses reserved records (0-15). Refuses
            directories (use `rm -r` for those).

            Behavior change in v0.2: bare argument is a PATH. Pass --recnum
            for the MFT-record-number form (legacy).
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Target: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let rn = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)
        try await volume.beginWriteSession()
        try await volume.deleteFile(at: rn)
        try await volume.endWriteSession()
        print("Deleted MFT record \(rn)")
    }
}
