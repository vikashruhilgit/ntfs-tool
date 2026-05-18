import ArgumentParser
import Foundation
import NTFSCore

struct Write: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write file content to an existing file.",
        discussion: """
            Two input modes:
              --from-file <path>: streams from a host file in 1 MiB chunks.
                No 1 GiB cap. Use this for videos / multi-GB inputs.
              (default): reads from stdin into memory. Practical ceiling is RSS.

            Three offset modes:
              --offset 0           rewrite from the start
              --offset <fileSize>  append
              --offset N           in-place mid-file overwrite (no extend)

            Behavior change in v0.2: bare target argument is a PATH. Pass
            --recnum for the MFT-record-number form.

            Marks the volume dirty before the write and clean (with fsync)
            after, so a crash leaves Windows aware that chkdsk should scan.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Target: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String

    @Option(name: [.short, .long], help: "Offset to write at. 0 = rewrite, file size = append, 0 < N <= size-bytes.count = in-place patch.")
    var offset: UInt64 = 0

    @Option(name: .long, help: "Stream content from this host file path instead of stdin. Required for files larger than ~1 GiB.")
    var fromFile: String?

    @Option(help: "Streaming chunk size in bytes (only used with --from-file). Default 1048576 (1 MiB).")
    var chunkSize: Int = 1 << 20

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let rn = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)

        try await volume.beginWriteSession()
        if let sourcePath = fromFile {
            let url = URL(fileURLWithPath: sourcePath)
            let size = try FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? UInt64 ?? 0
            try await volume.writeFile(at: rn, fromFileAt: url, chunkSize: chunkSize)
            try await volume.endWriteSession()
            print("Streamed \(size) bytes from \(sourcePath) into MFT record \(rn)")
        } else {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            try await volume.write(at: rn, offset: offset, bytes: bytes)
            try await volume.endWriteSession()
            print("Wrote \(bytes.count) bytes to MFT record \(rn) at offset \(offset)")
        }
    }
}
