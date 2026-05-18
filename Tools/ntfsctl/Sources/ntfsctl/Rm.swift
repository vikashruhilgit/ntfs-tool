import ArgumentParser
import Foundation
import NTFSCore

/// Delete files or recursively delete directory trees on an NTFS volume.
/// Mirrors `rm` / `rm -r` semantics. Paths preferred; --recnum for the
/// MFT-record-number form.
///
/// **Safety:** recursive deletes refuse to operate on root (MFT record 5)
/// and require `--force` for any other recursive target. A bare `rm -r`
/// on `/` previously enumerated all user files and deleted each one before
/// the final root-delete hit the "refuse reserved record" guard — leaving
/// the user with a wiped volume. Now: explicit root rejection + opt-in force.
struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove file(s) or directory tree(s) on an NTFS volume.",
        discussion: """
            Examples:
              # Remove one file by path:
              ntfsctl rm /dev/disk10s1 /Backups/draft.txt

              # Recursively remove a directory (requires --force for safety):
              ntfsctl rm -r --force /dev/disk10s1 /Backups/MyPhone

              # Preview first with --dry-run:
              ntfsctl rm -r --dry-run /dev/disk10s1 /Backups/MyPhone

            Safety:
              - `rm -r /` is explicitly rejected (no full-volume wipe by accident).
              - Recursive deletes require --force unless --dry-run.
              - Reserved MFT records (0-15) always rejected.

            Behavior change in v0.2: bare argument is a PATH. Pass --recnum
            for the MFT-record-number form.
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Target: path under volume root by default. Pass --recnum to target by MFT record number.")
    var target: String

    @Flag(name: [.short, .long], help: "Recursively remove directories.")
    var recursive: Bool = false

    @Flag(name: .long, help: "Required for non-empty recursive deletes (prevents accidental wipes).")
    var force: Bool = false

    @Flag(name: .long, help: "Print what would be deleted, don't actually delete.")
    var dryRun: Bool = false

    @Flag(name: [.short, .long], help: "Print each entry as it is removed.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Treat <target> as an MFT record number instead of a path.")
    var recnum: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let rn = try await TargetResolver.resolve(target, recnumFlag: recnum, volume: volume)

        // Hard refusal: root (recnum 5) and reserved records.
        if rn < 16 {
            throw ValidationError("refusing to remove reserved MFT record \(rn) (root + system files are off-limits)")
        }

        let mft = await volume.mft()
        let rec = try await mft.record(at: rn)
        if rec.isDirectory {
            if !recursive {
                throw ValidationError("\(target) is a directory; pass -r/--recursive (and --force) to remove it")
            }
            if !force && !dryRun {
                throw ValidationError("recursive delete requires --force (or --dry-run to preview). This is a safety guard — recursive deletes can't be undone.")
            }
        }

        if dryRun {
            try await walkAndReport(volume: volume, rn: rn, depth: 0)
            return
        }

        try await volume.beginWriteSession()
        try await removeRecursive(volume: volume, rn: rn)
        try await volume.endWriteSession()
    }

    private func walkAndReport(volume: NTFSCore.Volume, rn: UInt64, depth: Int) async throws {
        let mft = await volume.mft()
        let rec = try await mft.record(at: rn)
        let attrs = try rec.attributes()
        var name = "<recnum \(rn)>"
        if let fnAttr = attrs.first(where: { $0.type == .fileName }),
           case let .resident(b, _) = fnAttr.value,
           let fn = try? FileName.parse(b) {
            name = fn.name
        }
        let indent = String(repeating: "  ", count: depth)
        if rec.isDirectory {
            print("\(indent)\(name)/  (recnum \(rn))")
            let entries = try await volume.enumerate(directory: rn)
            for e in entries where e.fileName.namespace != .dos {
                try await walkAndReport(volume: volume, rn: e.recordNumber, depth: depth + 1)
            }
        } else {
            print("\(indent)\(name)  (recnum \(rn))")
        }
    }

    private func removeRecursive(volume: NTFSCore.Volume, rn: UInt64) async throws {
        let mft = await volume.mft()
        let rec = try await mft.record(at: rn)
        if rec.isDirectory {
            // Safety: under no circumstances should this recurse into root.
            // The caller already guarded rn < 16, but if anything in the
            // tree somehow points back to root, refuse rather than wipe.
            if rn < 16 {
                throw ValidationError("removeRecursive reached reserved record \(rn); aborting")
            }
            let entries = try await volume.enumerate(directory: rn)
            for e in entries where e.fileName.namespace != .dos {
                if e.recordNumber < 16 { continue }
                try await removeRecursive(volume: volume, rn: e.recordNumber)
            }
        }
        try await volume.deleteFile(at: rn)
        if verbose {
            FileHandle.standardError.write(Data("rm recnum \(rn)\n".utf8))
        }
    }
}
