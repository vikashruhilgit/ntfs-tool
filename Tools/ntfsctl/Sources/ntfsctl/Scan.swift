import ArgumentParser
import Foundation
import NTFSCore

/// Enumerate attached block devices and identify NTFS partitions by probing
/// their boot sectors. Saves users from manually parsing `diskutil list` for
/// the "Microsoft Basic Data" rows.
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "List attached NTFS partitions with size + free-space info.",
        discussion: """
            Walks /dev/disk*s* (block-device slices) and tries to parse each as
            an NTFS volume. Anything that parses prints its device path, total
            size, free space, and volume serial number.

            Pass --include-images to also probe `.img` files in the current
            directory (useful for working with fixtures).

            Requires sudo for raw device access.
            """
    )

    @Flag(name: .long, help: "Also probe .img files in the current directory.")
    var includeImages: Bool = false

    @Flag(name: [.short, .long], help: "Long format: include cluster size, MFT location.")
    var long: Bool = false

    func run() async throws {
        let fm = FileManager.default
        var candidates: [String] = []

        // Enumerate /dev/diskNsM slices. macOS exposes block-device slices as
        // /dev/disk0s1 etc.
        if let entries = try? fm.contentsOfDirectory(atPath: "/dev") {
            for entry in entries.sorted() {
                if entry.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil {
                    candidates.append("/dev/\(entry)")
                }
            }
        }

        if includeImages {
            if let files = try? fm.contentsOfDirectory(atPath: ".") {
                for f in files.sorted() where f.hasSuffix(".img") {
                    candidates.append(f)
                }
            }
        }

        var found = 0
        if long {
            print(padR("DEVICE", 22) + padR("SIZE", 14) + padR("FREE", 14) + padR("CLUSTER", 10) + padR("MFT@LCN", 10) + "SERIAL")
        } else {
            print(padR("DEVICE", 22) + padR("SIZE", 14) + padR("FREE", 14) + "SERIAL")
        }
        for path in candidates {
            guard let info = await probe(path) else { continue }
            found += 1
            if long {
                print(
                    padR(path, 22) +
                    padR(humanBytes(info.totalBytes), 14) +
                    padR(humanBytes(info.freeBytes), 14) +
                    padR("\(info.bytesPerCluster)", 10) +
                    padR("\(info.mftCluster)", 10) +
                    String(format: "0x%016llX", info.serial)
                )
            } else {
                print(
                    padR(path, 22) +
                    padR(humanBytes(info.totalBytes), 14) +
                    padR(humanBytes(info.freeBytes), 14) +
                    String(format: "0x%016llX", info.serial)
                )
            }
        }
        if found == 0 {
            FileHandle.standardError.write(Data("(no NTFS volumes found; use sudo if you got permission-denied errors)\n".utf8))
        }
    }

    private struct ProbedInfo {
        let totalBytes: UInt64
        let freeBytes: UInt64
        let bytesPerCluster: UInt32
        let mftCluster: UInt64
        let serial: UInt64
    }

    private func probe(_ path: String) async -> ProbedInfo? {
        do {
            let device = try FileHandleBlockDevice(openingFileAt: path)
            let volume = try await NTFSCore.Volume(device: device)
            let stats = try await volume.allocationStats()
            return ProbedInfo(
                totalBytes: stats.totalBytes,
                freeBytes: stats.freeBytes,
                bytesPerCluster: volume.bytesPerCluster,
                mftCluster: volume.boot.mftCluster,
                serial: volume.boot.volumeSerial
            )
        } catch {
            return nil
        }
    }

    private func padR(_ s: String, _ width: Int) -> String {
        if s.count >= width { return s + " " }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func humanBytes(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KiB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MiB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GiB", Double(n) / (1024 * 1024 * 1024))
    }
}
