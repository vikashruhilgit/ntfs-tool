import ArgumentParser
import Foundation
import NTFSCore

/// Copy a host file or directory tree into an NTFS volume. The recursive
/// (`-r`) mode walks the source directory, mirroring the structure on the
/// volume — files are streamed via `Volume.writeFile(at:fromFileAt:)`, so
/// any single file size is bounded only by free space, not by RSS.
///
/// Destination is a path under the volume root (with auto-resolve), so users
/// don't have to chase MFT record numbers.
struct Cp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy host files/directories into the NTFS volume (with optional recursive mode).",
        discussion: """
            Examples:
              # Copy one file into /Backups/ on the volume:
              ntfsctl cp /tmp/photo.jpg /dev/disk10s1 /Backups/

              # Recursive copy of a phone backup tree (creates intermediate dirs):
              ntfsctl cp -r ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

            Destination resolution:
              If destination ends with '/' OR is an existing directory on the
              volume, the source basename is appended. If destination is a
              non-existent path inside an existing parent, the source is copied
              under the given name. Intermediate destination directories are
              auto-created.

            Limitations:
              - Symlinks/hardlinks/devnodes in source are skipped (with warning).
              - Same LARGE_INDEX leaf-split limit applies as create: ~30-40
                inserts into a single fully-packed parent leaf will fail with
                'leaf full'. In practice the descent picks an under-full leaf
                for most real volumes.
            """
    )

    @Argument(help: "Host source file or directory.")
    var source: String

    @Argument(help: "Path to an NTFS block device or disk image (must be writable).")
    var device: String

    @Argument(help: "Destination path on the volume (under root). Trailing slash treats it as a directory.")
    var destination: String

    @Flag(name: [.short, .long], help: "Recursively copy directories.")
    var recursive: Bool = false

    @Option(help: "Streaming chunk size for file content writes. Default 1048576 (1 MiB).")
    var chunkSize: Int = 1 << 20

    func run() async throws {
        let fm = FileManager.default
        var srcIsDir: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &srcIsDir) else {
            throw ValidationError("source does not exist: \(source)")
        }
        if srcIsDir.boolValue && !recursive {
            throw ValidationError("source is a directory; pass -r/--recursive to copy directories")
        }

        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)

        // Resolve destination. Two shapes:
        //  - destination ends with '/' (or matches an existing directory) → copy
        //    under that directory using the source basename.
        //  - destination is a not-yet-existing leaf path → copy as that name.
        let endsWithSlash = destination.hasSuffix("/")
        let trimmedDest = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sourceBasename = (source as NSString).lastPathComponent

        let (destParent, destName) = try await resolveDestination(
            volume: volume,
            requested: trimmedDest,
            endsWithSlash: endsWithSlash,
            sourceBasename: sourceBasename
        )

        if srcIsDir.boolValue {
            let dirRN = try await ensureDirectory(volume: volume, parent: destParent, name: destName)
            try await copyDirectoryRecursive(
                volume: volume,
                hostDir: source,
                ntfsParent: dirRN
            )
        } else {
            try await copyOneFile(
                volume: volume,
                hostFile: source,
                ntfsParent: destParent,
                name: destName
            )
        }

        try await volume.setDirty(false)
    }

    /// Return (parentRecnum, leafName) describing where the source should
    /// land. Auto-creates intermediate destination directories that don't
    /// exist yet.
    private func resolveDestination(
        volume: NTFSCore.Volume,
        requested: String,
        endsWithSlash: Bool,
        sourceBasename: String
    ) async throws -> (UInt64, String) {
        if requested.isEmpty {
            return (5, sourceBasename)
        }
        let components = requested.split(separator: "/").map(String.init)
        // If the full path resolves to an existing directory, copy under it.
        if let resolved = try await volume.resolvePath(requested) {
            let entries = try await volume.enumerate(directory: 5)
            // Cheap "is it a directory" check via the parent: walk the path
            // ourselves so we can avoid re-enumerating root.
            _ = entries
            let isDir = try await isDirectory(volume: volume, recnum: resolved)
            if isDir {
                return (resolved, sourceBasename)
            }
            // Existing file at destination — refuse (no overwrite in v1).
            throw ValidationError("destination already exists as a file: /\(requested)")
        }
        // Path doesn't fully resolve. Auto-create parent dirs; the final
        // component becomes the leaf name (unless endsWithSlash, in which
        // case the user intended it as a directory).
        let leafName: String
        let parentComponents: [String]
        if endsWithSlash {
            leafName = sourceBasename
            parentComponents = components
        } else {
            guard let last = components.last else {
                return (5, sourceBasename)
            }
            leafName = last
            parentComponents = Array(components.dropLast())
        }

        var current: UInt64 = 5
        for comp in parentComponents {
            if let existing = try await childRecnum(volume: volume, parent: current, name: comp) {
                current = existing
            } else {
                current = try await volume.createFile(named: comp, inDirectory: current, isDirectory: true)
            }
        }
        return (current, leafName)
    }

    private func isDirectory(volume: NTFSCore.Volume, recnum: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        let rec = try await mft.record(at: recnum)
        return rec.isDirectory
    }

    private func childRecnum(volume: NTFSCore.Volume, parent: UInt64, name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos &&
            $0.name.lowercased() == needle
        }?.recordNumber
    }

    private func ensureDirectory(volume: NTFSCore.Volume, parent: UInt64, name: String) async throws -> UInt64 {
        if let existing = try await childRecnum(volume: volume, parent: parent, name: name) {
            if try await isDirectory(volume: volume, recnum: existing) { return existing }
            throw ValidationError("destination /\(name) exists as a file, refusing to clobber")
        }
        return try await volume.createFile(named: name, inDirectory: parent, isDirectory: true)
    }

    private func copyOneFile(
        volume: NTFSCore.Volume,
        hostFile: String,
        ntfsParent: UInt64,
        name: String
    ) async throws {
        let url = URL(fileURLWithPath: hostFile)
        // Reject special files (symlinks, devices, etc.) — they don't map.
        let attrs = try FileManager.default.attributesOfItem(atPath: hostFile)
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            FileHandle.standardError.write(Data("skip \(hostFile): not a regular file (\(type.rawValue))\n".utf8))
            return
        }
        // If a same-named entry already exists in the parent, delete it so we
        // can recreate. v1 has no "overwrite in place" semantics.
        if let existing = try await childRecnum(volume: volume, parent: ntfsParent, name: name) {
            try await volume.deleteFile(at: existing)
        }
        let rn = try await volume.createFile(named: name, inDirectory: ntfsParent, isDirectory: false)
        let size = attrs[.size] as? UInt64 ?? 0
        if size == 0 {
            // Empty file — no content write needed.
            FileHandle.standardError.write(Data("cp \(hostFile) -> recnum \(rn) (empty)\n".utf8))
            return
        }
        try await volume.writeFile(at: rn, fromFileAt: url, chunkSize: chunkSize)
        FileHandle.standardError.write(Data("cp \(hostFile) -> recnum \(rn) (\(size) bytes)\n".utf8))
    }

    private func copyDirectoryRecursive(
        volume: NTFSCore.Volume,
        hostDir: String,
        ntfsParent: UInt64
    ) async throws {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: hostDir)
        } catch {
            FileHandle.standardError.write(Data("skip \(hostDir): \(error)\n".utf8))
            return
        }
        // Deterministic order makes the resulting tree predictable.
        for name in entries.sorted() {
            let fullPath = (hostDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let childRN = try await ensureDirectory(volume: volume, parent: ntfsParent, name: name)
                try await copyDirectoryRecursive(volume: volume, hostDir: fullPath, ntfsParent: childRN)
            } else {
                try await copyOneFile(volume: volume, hostFile: fullPath, ntfsParent: ntfsParent, name: name)
            }
        }
    }
}
