import ArgumentParser
import Foundation
import NTFSCore

struct Truncate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "truncate",
        abstract: "Resize an existing file (shrink only, byte-precise).",
        discussion: """
            New size may be any value ≤ existing size. Non-cluster-aligned
            shrinks work — the trailing partial cluster keeps its slack.
            Growing via truncate isn't supported; use `write` to extend.

            Behavior change in v0.2: bare target argument is a PATH. Pass
            --recnum for the MFT-record-number form.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Target: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String

    @Argument(help: "New file size in bytes. 0 frees all clusters and resets $DATA to empty resident.")
    var newSize: UInt64

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let rn = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)
        try await volume.beginWriteSession()
        try await volume.truncate(at: rn, newSize: newSize)
        try await volume.endWriteSession()
        print("Truncated MFT record \(rn) to \(newSize) bytes")
    }
}
