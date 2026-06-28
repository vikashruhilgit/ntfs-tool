import ArgumentParser
import Foundation
import NTFSCore

struct Format: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "format",
        abstract: "Create a fresh NTFS filesystem on a device or image (DESTRUCTIVE).",
        discussion: """
            Writes a complete NTFS 3.1 volume (boot sector + backup, $MFT/$MFTMirr,
            $LogFile, $Bitmap, $UpCase, $AttrDef, $Secure with $SDS/$SDH/$SII, root
            directory listing all system metafiles). EVERYTHING on the target is
            ERASED.

            Safety: refuses to run without --force, and refuses a device that is
            currently mounted (unmount it first, e.g. `diskutil unmount /dev/diskNs1`).
            Reading/writing a real /dev/disk* device requires sudo.

            Example:
              diskutil unmount /dev/disk6s1
              sudo ntfsctl format /dev/disk6s1 --label MYDRIVE --force
            """
    )

    @Argument(help: "Path to the target block device or image file. ALL DATA IS ERASED.")
    var device: String

    @Option(name: .long, help: "Volume label (default: empty).")
    var label: String = ""

    @Flag(name: .long, help: "Required. Confirms you accept that the target is erased.")
    var force: Bool = false

    func run() async throws {
        guard force else {
            throw ValidationError("""
                Refusing to format \(device) without --force.
                This ERASES ALL DATA on the target. Re-run with --force once you are
                certain of the device path (double-check with `diskutil list`).
                """)
        }

        // Refuse a mounted device — formatting underneath a live mount corrupts.
        if let mountedAt = Self.mountPoint(forBSDPath: device) {
            throw ValidationError("""
                \(device) is currently mounted at \(mountedAt). Unmount it first:
                  diskutil unmount \(device)
                then re-run.
                """)
        }

        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let size = try await blockDevice.size()
        guard size >= 2 * 1024 * 1024 else {
            throw ValidationError("device \(device) is only \(size) bytes — too small for NTFS (need ≥ ~2 MiB)")
        }
        let mib = Double(size) / (1024 * 1024)
        FileHandle.standardError.write(Data("Formatting \(device) (\(String(format: "%.1f", mib)) MiB) as NTFS…\n".utf8))

        try await Volume.formatNTFS(
            device: blockDevice,
            deviceSizeBytes: size,
            label: label
        )
        try await blockDevice.synchronize()

        // Re-open read-only and confirm it parses.
        let verifyDevice = try FileHandleBlockDevice(openingFileAt: device)
        let vol = try await NTFSCore.Volume(device: verifyDevice)
        let entries = try await vol.enumerate(directory: 5)
        let userVisible = entries.filter { !$0.name.hasPrefix("$") && $0.name != "." }
        print("Formatted NTFS volume on \(device): \(String(format: "%.1f", mib)) MiB, label \"\(label)\".")
        print("Root contains \(entries.count) entries (\(userVisible.count) user-visible). Eject before unplugging:")
        print("  diskutil eject \(device)")
    }

    /// Returns the mount point if `bsdPath` (/dev/diskNsM) is mounted, else nil.
    /// Best-effort parse of `/sbin/mount` output.
    static func mountPoint(forBSDPath bsdPath: String) -> String? {
        guard bsdPath.hasPrefix("/dev/") else { return nil }
        let dev = bsdPath.replacingOccurrences(of: "/dev/r", with: "/dev/")  // rdiskN → diskN
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix(dev + " ") {
            // "/dev/diskNsM on /Volumes/Foo (ntfs, ...)"
            if let r = line.range(of: " on ") {
                let rest = line[r.upperBound...]
                if let paren = rest.range(of: " (") {
                    return String(rest[..<paren.lowerBound])
                }
            }
        }
        return nil
    }
}
