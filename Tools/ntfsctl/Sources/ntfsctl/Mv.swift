import ArgumentParser
import Foundation
import NTFSCore

/// Rename / move a file or directory on an NTFS volume. Removes the source's
/// $I30 entry from its current parent, updates $FILE_NAME with the new name
/// (and parent reference if moving), inserts a new $I30 entry under the
/// destination's parent.
struct Mv: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Rename or move a file/directory on an NTFS volume.",
        discussion: """
            Examples:
              # Simple rename in the same directory:
              ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

              # Move into a different directory (auto-creates parent if missing):
              ntfsctl mv /dev/disk10s1 /Backups/draft.txt /Archive/final.txt

              # Don't overwrite an existing destination (skip):
              ntfsctl mv -n /dev/disk10s1 /Backups/draft.txt /Backups/final.txt

            Conflict handling (existing destination):
              - default          : replace (delete the existing destination, then
                                   move the source onto its name). Replace applies
                                   to an existing file or an EMPTY directory; a
                                   populated directory destination is refused.
              - -n/--no-clobber  : skip (leave the existing destination untouched
                                   and exit 0 without moving).

            Limitations:
              - Move is within a single NTFS volume only (rename / relocate on the
                same drive). For a cross-device move (host <-> volume) use
                `cp --move` (copy then delete each source).
            """
    )

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Source path on the volume.")
    var source: String

    @Argument(help: "Destination path on the volume (rename target).")
    var destination: String

    @Flag(name: [.short, .long], help: "Don't overwrite an existing destination (skip).")
    var noClobber: Bool = false

    func run() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        guard let srcRN = try await volume.resolvePath(source) else {
            throw ValidationError("source path not found: \(source)")
        }
        // Split destination into parent + leaf name.
        let trimmed = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/").map(String.init)
        guard let leafName = components.last else {
            throw ValidationError("destination must include a final name component: \(destination)")
        }
        let parentComponents = Array(components.dropLast())
        var parentRN: UInt64 = 5
        for comp in parentComponents {
            let entries = try await volume.enumerate(directory: parentRN)
            if let match = entries.first(where: { $0.name.lowercased() == comp.lowercased() && $0.fileName.namespace != .dos }) {
                parentRN = match.recordNumber
            } else {
                // Auto-create intermediate directories.
                parentRN = try await volume.createFile(named: comp, inDirectory: parentRN, isDirectory: true)
            }
        }

        // AC-6: reuse cp's conflict policy. -n => skip, default => replace.
        let conflict: DestinationOutcome.ConflictPolicy = noClobber ? .skip : .replace

        // Does the destination NAME already exist under the resolved parent?
        // (DOS-namespace filtered, matching the lookup style elsewhere.)
        let destEntries = try await volume.enumerate(directory: parentRN)
        let existingRN = destEntries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == leafName.lowercased()
        }?.recordNumber

        if let existingRN {
            // DATA-LOSS GUARD: the dest-exists lookup matches CASE-INSENSITIVELY,
            // so `existingRN` can be the SOURCE record itself — either an exact
            // self-move (`mv /a.txt /a.txt`) or a legitimate case-only rename
            // (`mv /A.txt /a.txt`). Without this guard the .replace branch would
            // deleteFile(existingRN==srcRN) and then rename a now-deleted record,
            // destroying the file. INVARIANT: when existingRN == srcRN, the
            // source is NEVER deleted.
            if existingRN == srcRN {
                // Read the source's current on-disk name to distinguish the two.
                let mft = await volume.mft()
                let srcRec = try await mft.record(at: srcRN)
                let srcAttrs = try srcRec.attributes()
                var currentName: String? = nil
                if let fnAttr = srcAttrs.first(where: { $0.type == .fileName }),
                   case let .resident(fnBytes, _) = fnAttr.value,
                   let fn = try? FileName.parse(fnBytes) {
                    currentName = fn.name
                }

                if currentName == leafName {
                    // Exact self-move: renaming to the identical name. Clean no-op.
                    // Do NOT deleteFile, do NOT rename (rename refuses the exact
                    // same-name collision anyway).
                    print("mv: \(source) and \(destination) are the same file; nothing to do")
                    return
                }
                // Case-only rename (existingRN == srcRN, requested name differs
                // from the current name only in case). Plain rename — NEVER
                // deleteFile. Volume.rename updates $FILE_NAME to the new casing,
                // and its duplicate-name guard is case-SENSITIVE so it won't
                // false-trip on the source's own (differently-cased) entry.
                try await volume.beginWriteSession()
                try await volume.rename(at: srcRN, toName: leafName, inDirectory: parentRN)
                try await volume.endWriteSession()
                print("mv \(source) -> \(destination) (recnum \(srcRN), case-only rename)")
                return
            }
            switch conflict {
            case .skip:
                // AC-6 skip: no-op, exit 0. Do NOT rename, do NOT delete.
                print("mv: \(destination) exists, skipping (-n)")
                return
            case .replace:
                // AC-7 safety guard: deleteFile is for files / empty dirs only.
                // Refuse to clobber a POPULATED directory (would orphan its
                // children). Replace targets an existing file or an empty dir.
                let mft = await volume.mft()
                let existingRec = try await mft.record(at: existingRN)
                if existingRec.isDirectory {
                    let children = try await volume.enumerate(directory: existingRN)
                        .filter { $0.fileName.namespace != .dos && $0.name != "." && $0.name != ".." }
                    if !children.isEmpty {
                        throw ValidationError(
                            "destination \(destination) is a non-empty directory; refusing to replace (would orphan its contents)"
                        )
                    }
                }
                // AC-7: delete-existing + atomic rename inside one write session.
                // The dirty bit is for chkdsk; the actual source-never-lost
                // atomicity comes from rename being insert-before-remove. Order:
                // begin -> deleteFile(existing) -> rename(source -> dest) -> end.
                // If rename throws, the source is still reachable (from its old
                // parent and/or the just-committed dest edge) — never lost.
                try await volume.beginWriteSession()
                try await volume.deleteFile(at: existingRN)
                try await volume.rename(at: srcRN, toName: leafName, inDirectory: parentRN)
                try await volume.endWriteSession()
                print("mv \(source) -> \(destination) (recnum \(srcRN), replaced recnum \(existingRN))")
                return
            }
        }

        // Destination does not exist: plain rename (unchanged behavior).
        try await volume.beginWriteSession()
        try await volume.rename(at: srcRN, toName: leafName, inDirectory: parentRN)
        try await volume.endWriteSession()
        print("mv \(source) -> \(destination) (recnum \(srcRN))")
    }
}
