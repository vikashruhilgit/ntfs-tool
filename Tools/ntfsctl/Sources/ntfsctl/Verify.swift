import ArgumentParser
import Foundation
import NTFSCore

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Read-only sanity check — boot sector + MFT records 0/5/16-31 parse cleanly."
    )

    @Argument(help: "Path to an NTFS block device or disk image.")
    var device: String

    @Flag(name: [.short, .long], help: "Print per-record details.")
    var verbose: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let mft = await volume.mft()

        print("Boot sector:              OK  (\(volume.boot.oemID.trimmingCharacters(in: .whitespaces)))")

        var inUseCount = 0
        var freeCount = 0
        var errorCount = 0
        let recordsToCheck: [UInt64] = [0, 5] + Array(UInt64(16)...UInt64(63))

        for n in recordsToCheck {
            do {
                let record = try await mft.record(at: n)
                if record.isInUse {
                    inUseCount += 1
                    if verbose {
                        let attrs = (try? record.attributes()) ?? []
                        let kinds = attrs.compactMap { $0.type }.map { String(describing: $0) }.joined(separator: ",")
                        print(String(format: "MFT %4llu  IN_USE  attrs: %s", n, kinds))
                    }
                } else {
                    freeCount += 1
                }
            } catch {
                errorCount += 1
                if verbose {
                    print(String(format: "MFT %4llu  ERROR   \(error.localizedDescription)", n))
                }
            }
        }

        print("MFT records:")
        print("  In use:                 \(inUseCount)")
        print("  Free:                   \(freeCount)")
        print("  Errors:                 \(errorCount)")

        // Walk root directory to confirm $I30 parsing works.
        let rootEntries = try await volume.enumerate(directory: 5)
        let canonical = rootEntries.filter { $0.fileName.namespace != .dos }
        print("Root directory entries:   \(canonical.count) (\(rootEntries.count) including DOS aliases)")

        if errorCount > 0 {
            print("\nVerify FAILED (\(errorCount) records with parse errors).")
            throw ExitCode(1)
        }
        print("\nVerify PASSED.")
    }
}
