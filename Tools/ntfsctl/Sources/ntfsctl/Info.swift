import ArgumentParser
import Foundation
import NTFSCore

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print volume metadata (boot sector + MFT placement)."
    )

    @Argument(help: "Path to an NTFS block device (/dev/diskNsM) or disk image file.")
    var device: String

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let boot = volume.boot

        let totalBytes = boot.totalSectors * UInt64(boot.bytesPerSector)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false

        print("Device:                   \(device)")
        print("OEM ID:                   '\(boot.oemID)'")
        print("Bytes per sector:         \(boot.bytesPerSector)")
        print("Sectors per cluster:      \(boot.sectorsPerCluster)")
        print("Bytes per cluster:        \(volume.bytesPerCluster)")
        print("Total sectors:            \(boot.totalSectors)  (\(formatter.string(fromByteCount: Int64(totalBytes))))")
        print("MFT cluster:              \(boot.mftCluster)  (byte offset \(volume.mftByteOffset))")
        print("MFT mirror cluster:       \(boot.mftMirrorCluster)")
        print("MFT record size:          \(volume.mftRecordSizeBytes) bytes")
        print("Index record size:        \(volume.indexRecordSizeBytes) bytes")
        print("Volume serial:            0x\(String(boot.volumeSerial, radix: 16, uppercase: true))")
        print("Boot signature:           0x\(String(format: "%04X", boot.bootSectorSignature))")

        // Free-space stats from $Bitmap (Phase 5a). Best-effort — a corrupt
        // $Bitmap shouldn't fail `ntfsctl info`, just suppresses these lines.
        if let stats = try? await volume.allocationStats() {
            print("Total clusters:           \(stats.totalClusters)")
            print("Free clusters:            \(stats.freeClusters)  (\(formatter.string(fromByteCount: Int64(stats.freeBytes))))")
            print("Allocated clusters:       \(stats.allocatedClusters)  (\(formatter.string(fromByteCount: Int64(stats.allocatedBytes))))")
        }
    }
}
