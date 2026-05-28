import ArgumentParser
import Foundation
import NTFSCore

struct Mkntfs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkntfs",
        abstract: "Create a fresh NTFS volume on a block device or disk image.",
        discussion: """
            DESTRUCTIVE: overwrites all data on <device>. Equivalent to
            `mkntfs -Q` (quick format — no bad-cluster sweep). Output is
            mountable by macOS livefiles_ntfs, Linux ntfs-3g, and Windows
            (data volumes only — not a bootable Windows install).

            Safety: refuses to run unless --yes is passed. Always prints
            the device path, size, and label first; consider running
            against a disk image (.img) before a real device.
            """
    )

    @Argument(help: "Path to the block device or disk image to format.")
    var device: String

    @Option(name: [.short, .long], help: "Volume label (UTF-16). Default: empty.")
    var label: String = ""

    @Flag(name: .long, help: "Quick format (default — matches mkntfs -Q). Currently the only supported mode.")
    var quick: Bool = false

    @Flag(name: .long, help: "Confirm the destructive operation. Required.")
    var yes: Bool = false

    @Option(name: .long, help: "Override the volume serial (8 bytes, hex). Default: random.")
    var serial: String?

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let size = try await blockDevice.size()
        let sizeMiB = Double(size) / (1024 * 1024)

        // Print the plan first.
        FileHandle.standardError.write(Data("""
            mkntfs target:
              device: \(device)
              size:   \(String(format: "%.2f", sizeMiB)) MiB (\(size) bytes)
              label:  \(label.isEmpty ? "<none>" : label)

            THIS WILL DESTROY ALL DATA ON \(device).

            """.utf8))

        guard yes else {
            throw ValidationError("Pass --yes to confirm. Aborting (no data written).")
        }

        let parsedSerial: UInt64?
        if let s = serial {
            guard let v = UInt64(s, radix: 16) else {
                throw ValidationError("--serial must be a 16-digit hex value (got '\(s)')")
            }
            parsedSerial = v
        } else {
            parsedSerial = nil
        }

        try await Volume.formatNTFS(
            device: blockDevice,
            deviceSizeBytes: size,
            label: label,
            quick: true,
            volumeSerial: parsedSerial
        )

        print("Formatted \(device) as NTFS (\(String(format: "%.2f", sizeMiB)) MiB, label='\(label)').")
        print("Verify with: ntfsctl info \(device)")
    }
}
