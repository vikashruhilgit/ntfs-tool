import ArgumentParser
import Foundation
import NTFSCore

/// Copy files / directory trees between host and NTFS volume.
///
/// Default direction is host → volume. Pass `--from-volume` to invert
/// (volume → host: pull files off the NTFS drive onto local disk).
struct Cp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy host ↔ NTFS files/directories (recursive, streaming, with progress).",
        discussion: """
            Examples:
              # Host → volume:
              ntfsctl cp /tmp/photo.jpg /dev/disk10s1 /Backups/
              ntfsctl cp -r ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

              # Volume → host (with --from-volume):
              ntfsctl cp --from-volume /Backups/MyPhone/IMG_001.jpg /dev/disk10s1 ~/restored/
              ntfsctl cp -r --from-volume /Backups/MyPhone /dev/disk10s1 ~/restored/

              # Preview only (no writes):
              ntfsctl cp -r --dry-run ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

              # Don't overwrite existing destination files, show progress:
              ntfsctl cp -r -n --progress ~/PhoneBackup /dev/disk10s1 /Backups/MyPhone

            Limitations:
              - Symlinks/hardlinks/devnodes in source are skipped (with warning).
              - LARGE_INDEX leaf-split is not yet implemented: copying many
                files into a single fresh directory caps at ~30-50 files per
                directory before hitting `unsupportedFeature(leaf full)`.
                Existing Windows-formatted dirs typically have multi-leaf
                trees and accept many more inserts.
              - Free-space pre-check runs by default for recursive copies in
                the host → volume direction (pass --no-free-check to skip).
            """
    )

    @Argument(help: "Source: host path (default direction) OR volume path (with --from-volume).")
    var source: String

    @Argument(help: "Path to an NTFS block device or disk image (must be writable for host→volume).")
    var device: String

    @Argument(help: "Destination: volume path (default) OR host path (with --from-volume). Trailing slash treats it as a directory.")
    var destination: String

    @Flag(name: [.short, .long], help: "Recursively copy directories.")
    var recursive: Bool = false

    @Flag(name: .long, help: "Invert direction: pull from volume → host.")
    var fromVolume: Bool = false

    @Flag(name: [.short, .long], help: "Don't overwrite existing destination files.")
    var noClobber: Bool = false

    @Flag(name: [.short, .long], help: "Verbose: print each file as it's copied.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Show progress (files / bytes / running total).")
    var progress: Bool = false

    @Flag(name: .long, help: "Don't write anything; print the planned operations and totals.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Skip the free-space pre-check (host→volume only).")
    var noFreeCheck: Bool = false

    @Option(help: "Streaming chunk size for file content writes. Default 1048576 (1 MiB).")
    var chunkSize: Int = 1 << 20

    // MARK: - Plan

    private struct CopyPlan {
        var files: [(source: String, destDir: String, name: String, size: UInt64)] = []
        var dirs: [(destParentSpec: String, name: String)] = []   // dirs that need creation
        var totalBytes: UInt64 = 0
    }

    func run() async throws {
        if fromVolume {
            try await runVolumeToHost()
        } else {
            try await runHostToVolume()
        }
    }

    // MARK: - Host → Volume

    private func runHostToVolume() async throws {
        let fm = FileManager.default
        var srcIsDir: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &srcIsDir) else {
            throw ValidationError("source does not exist: \(source) (hint: check the host path; pass --from-volume if the source is on the NTFS device)")
        }
        if srcIsDir.boolValue && !recursive {
            throw ValidationError("source is a directory; pass -r/--recursive to copy directories")
        }

        let blockDevice = try FileHandleBlockDevice(openingFileForUpdateAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)

        // Resolve where the source lands.
        let endsWithSlash = destination.hasSuffix("/")
        let trimmedDest = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sourceBasename = (source as NSString).lastPathComponent
        let (destParent, destName) = try await resolveDestination(
            volume: volume,
            requested: trimmedDest,
            endsWithSlash: endsWithSlash,
            sourceBasename: sourceBasename
        )

        // Scan source to build a plan + size totals.
        var totalFiles = 0
        var totalBytes: UInt64 = 0
        if srcIsDir.boolValue {
            try walkHostDir(source) { _, fileSize in
                totalFiles += 1
                totalBytes += fileSize
            }
        } else {
            totalFiles = 1
            totalBytes = (try fm.attributesOfItem(atPath: source)[.size] as? UInt64) ?? 0
        }

        // Free-space pre-check.
        if !noFreeCheck {
            let stats = try await volume.allocationStats()
            if totalBytes > stats.freeBytes {
                throw ValidationError(
                    "insufficient free space: source needs \(humanBytes(totalBytes)) but volume has \(humanBytes(stats.freeBytes)) free (pass --no-free-check to override; LARGE_INDEX leaf-full may still cap directories)"
                )
            }
        }

        if dryRun {
            FileHandle.standardOutput.write(Data("DRY-RUN: would copy \(totalFiles) file(s), \(humanBytes(totalBytes)) total → /\(joinedDestPath(destParent: destParent, name: destName, volume: volume))\n".utf8))
            return
        }

        // Mark the volume dirty for the duration of the copy so a crash leaves
        // Windows aware that chkdsk should scan the volume on next mount.
        try await volume.beginWriteSession()

        // Execute the copy.
        var copiedFiles = 0
        var copiedBytes: UInt64 = 0
        if srcIsDir.boolValue {
            let dirRN = try await ensureDirectory(volume: volume, parent: destParent, name: destName)
            try await copyDirectoryRecursive(
                volume: volume,
                hostDir: source,
                ntfsParent: dirRN,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes
            )
        } else {
            try await copyOneFile(
                volume: volume,
                hostFile: source,
                ntfsParent: destParent,
                name: destName,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes
            )
        }
        try await volume.endWriteSession()

        if progress || verbose {
            FileHandle.standardError.write(Data("done: \(copiedFiles)/\(totalFiles) files, \(humanBytes(copiedBytes))/\(humanBytes(totalBytes))\n".utf8))
        }
    }

    private func joinedDestPath(destParent: UInt64, name: String, volume _: NTFSCore.Volume) -> String {
        // Approximate display: we don't reverse-resolve parent → path here;
        // print parent recnum + name for transparency.
        return "(parent recnum \(destParent))/\(name)"
    }

    private func walkHostDir(_ root: String, visit: (_ path: String, _ size: UInt64) throws -> Void) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for name in entries.sorted() {
            let full = (root as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try walkHostDir(full, visit: visit)
            } else {
                let size = (try fm.attributesOfItem(atPath: full)[.size] as? UInt64) ?? 0
                try visit(full, size)
            }
        }
    }

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
        if let resolved = try await volume.resolvePath(requested) {
            let isDir = try await isDirectory(volume: volume, recnum: resolved)
            if isDir {
                return (resolved, sourceBasename)
            }
            throw ValidationError("destination already exists as a file: /\(requested) (pass to a directory ending with '/' to copy under it)")
        }
        let leafName: String
        let parentComponents: [String]
        if endsWithSlash {
            leafName = sourceBasename
            parentComponents = components
        } else {
            guard let last = components.last else { return (5, sourceBasename) }
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
        name: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64
    ) async throws {
        let url = URL(fileURLWithPath: hostFile)
        let attrs = try FileManager.default.attributesOfItem(atPath: hostFile)
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            FileHandle.standardError.write(Data("skip \(hostFile): not a regular file (\(type.rawValue))\n".utf8))
            return
        }
        if let existing = try await childRecnum(volume: volume, parent: ntfsParent, name: name) {
            if noClobber {
                if verbose { FileHandle.standardError.write(Data("skip \(hostFile) → already exists\n".utf8)) }
                return
            }
            try await volume.deleteFile(at: existing)
        }
        let rn = try await volume.createFile(named: name, inDirectory: ntfsParent, isDirectory: false)
        let size = attrs[.size] as? UInt64 ?? 0
        if size > 0 {
            try await volume.writeFile(at: rn, fromFileAt: url, chunkSize: chunkSize)
        }
        copiedFiles += 1
        copiedBytes += size
        if verbose {
            FileHandle.standardError.write(Data("cp \(hostFile) -> recnum \(rn) (\(humanBytes(size)))\n".utf8))
        }
        if progress {
            let pct = totalBytes == 0 ? 100.0 : Double(copiedBytes) / Double(totalBytes) * 100
            FileHandle.standardError.write(Data("[\(copiedFiles)/\(totalFiles)] \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)) (\(String(format: "%.1f", pct))%) - \(name)\n".utf8))
        }
    }

    private func copyDirectoryRecursive(
        volume: NTFSCore.Volume,
        hostDir: String,
        ntfsParent: UInt64,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64
    ) async throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: hostDir)) ?? []

        // v0.4 Phase 1: separate subdirs from files so we can recurse first
        // and then process this level's file batch under one beginBulkInsert
        // / endBulkInsert window. Nesting begin/end isn't supported (Volume
        // throws), so we MUST finish recursion (each of which enters its
        // own begin/end at the child level) BEFORE opening this level's
        // bulk-insert window.
        var subdirs: [(name: String, fullPath: String)] = []
        var files: [(name: String, fullPath: String)] = []
        for name in entries.sorted() {
            let fullPath = (hostDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                subdirs.append((name, fullPath))
            } else {
                files.append((name, fullPath))
            }
        }

        // 1) Recurse into subdirs first. Each recursion may open its own
        //    bulk-insert window at the child level — that's fine because
        //    THIS level's window is still closed.
        for (name, fullPath) in subdirs {
            let childRN = try await ensureDirectory(volume: volume, parent: ntfsParent, name: name)
            try await copyDirectoryRecursive(
                volume: volume,
                hostDir: fullPath,
                ntfsParent: childRN,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes
            )
        }

        // 2) Now copy this level's files inside one bulk-insert window.
        //    Per-file refreshParentI30Size calls become no-ops; size hints
        //    will show as 0 in Windows Explorer until a subsequent write
        //    or explicit hint-refresh updates them. File contents are
        //    byte-correct on disk.
        guard !files.isEmpty else { return }
        try await volume.beginBulkInsert(into: ntfsParent)
        do {
            for (name, fullPath) in files {
                try await copyOneFile(
                    volume: volume,
                    hostFile: fullPath,
                    ntfsParent: ntfsParent,
                    name: name,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes
                )
            }
            _ = try await volume.endBulkInsert()
        } catch {
            _ = try? await volume.endBulkInsert()
            throw error
        }
    }

    // MARK: - Volume → Host (--from-volume)

    private func runVolumeToHost() async throws {
        let blockDevice = try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)

        guard let srcRN = try await volume.resolvePath(source) else {
            throw ValidationError("volume path not found: \(source) (hint: check `ntfsctl list` to confirm the path; case-insensitive on ASCII)")
        }
        let srcIsDir = try await isDirectory(volume: volume, recnum: srcRN)
        if srcIsDir && !recursive {
            throw ValidationError("volume source is a directory; pass -r/--recursive")
        }

        let fm = FileManager.default
        // Resolve host destination: if it ends with '/' or exists-as-directory, copy under it.
        let hostDest = (destination as NSString).expandingTildeInPath
        let sourceBasename = (source.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent
        let endsWithSlash = destination.hasSuffix("/")
        var hostIsDir: ObjCBool = false
        let hostExists = fm.fileExists(atPath: hostDest, isDirectory: &hostIsDir)

        let finalHostPath: String
        if hostExists, hostIsDir.boolValue {
            finalHostPath = (hostDest as NSString).appendingPathComponent(sourceBasename)
        } else if endsWithSlash {
            try fm.createDirectory(atPath: hostDest, withIntermediateDirectories: true)
            finalHostPath = (hostDest as NSString).appendingPathComponent(sourceBasename)
        } else {
            finalHostPath = hostDest
            try fm.createDirectory(
                atPath: (finalHostPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        }

        // Walk + count for progress (cheap — just enumerate, no file data).
        var totalFiles = 0
        var totalBytes: UInt64 = 0
        if srcIsDir {
            try await walkVolumeDir(volume: volume, dirRN: srcRN) { _, size, _ in
                totalFiles += 1
                totalBytes += size
            }
        } else {
            totalFiles = 1
            let mft = await volume.mft()
            let rec = try await mft.record(at: srcRN)
            let attrs = try rec.attributes()
            if let d = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) {
                switch d.value {
                case let .resident(b, _): totalBytes = UInt64(b.count)
                case let .nonResident(_, _, _, _, _, r, _, _): totalBytes = r
                }
            }
        }

        if dryRun {
            FileHandle.standardOutput.write(Data("DRY-RUN: would pull \(totalFiles) file(s), \(humanBytes(totalBytes)) total → \(finalHostPath)\n".utf8))
            return
        }

        var copiedFiles = 0
        var copiedBytes: UInt64 = 0
        if srcIsDir {
            try fm.createDirectory(atPath: finalHostPath, withIntermediateDirectories: true)
            try await pullDirRecursive(
                volume: volume,
                volumeDirRN: srcRN,
                hostDir: finalHostPath,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes
            )
        } else {
            try await pullOneFile(
                volume: volume,
                rn: srcRN,
                hostPath: finalHostPath,
                fileName: sourceBasename,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes
            )
        }

        if progress || verbose {
            FileHandle.standardError.write(Data("done: \(copiedFiles)/\(totalFiles) files, \(humanBytes(copiedBytes))/\(humanBytes(totalBytes))\n".utf8))
        }
    }

    private func walkVolumeDir(
        volume: NTFSCore.Volume,
        dirRN: UInt64,
        visit: (UInt64, UInt64, String) async throws -> Void
    ) async throws {
        let entries = try await volume.enumerate(directory: dirRN)
        for e in entries where e.fileName.namespace != .dos {
            if e.isDirectory {
                try await walkVolumeDir(volume: volume, dirRN: e.recordNumber, visit: visit)
            } else {
                try await visit(e.recordNumber, e.fileName.realSize, e.name)
            }
        }
    }

    private func pullOneFile(
        volume: NTFSCore.Volume,
        rn: UInt64,
        hostPath: String,
        fileName: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64
    ) async throws {
        let fm = FileManager.default
        if noClobber && fm.fileExists(atPath: hostPath) {
            if verbose { FileHandle.standardError.write(Data("skip \(hostPath) → already exists\n".utf8)) }
            return
        }
        fm.createFile(atPath: hostPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: hostPath) else {
            throw ValidationError("cannot open host file for writing: \(hostPath)")
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        let chunk = chunkSize
        var fileSize: UInt64 = 0
        while true {
            let data = try await volume.readFileSlice(at: rn, offset: offset, length: chunk)
            if data.isEmpty { break }
            try handle.write(contentsOf: data)
            offset += UInt64(data.count)
            fileSize += UInt64(data.count)
            if data.count < chunk { break }
        }
        copiedFiles += 1
        copiedBytes += fileSize
        if verbose {
            FileHandle.standardError.write(Data("pull \(fileName) (recnum \(rn)) -> \(hostPath) (\(humanBytes(fileSize)))\n".utf8))
        }
        if progress {
            let pct = totalBytes == 0 ? 100.0 : Double(copiedBytes) / Double(totalBytes) * 100
            FileHandle.standardError.write(Data("[\(copiedFiles)/\(totalFiles)] \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)) (\(String(format: "%.1f", pct))%) - \(fileName)\n".utf8))
        }
    }

    private func pullDirRecursive(
        volume: NTFSCore.Volume,
        volumeDirRN: UInt64,
        hostDir: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64
    ) async throws {
        let fm = FileManager.default
        let entries = try await volume.enumerate(directory: volumeDirRN)
        for e in entries where e.fileName.namespace != .dos {
            let hostChild = (hostDir as NSString).appendingPathComponent(e.name)
            if e.isDirectory {
                try fm.createDirectory(atPath: hostChild, withIntermediateDirectories: true)
                try await pullDirRecursive(
                    volume: volume,
                    volumeDirRN: e.recordNumber,
                    hostDir: hostChild,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes
                )
            } else {
                try await pullOneFile(
                    volume: volume,
                    rn: e.recordNumber,
                    hostPath: hostChild,
                    fileName: e.name,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes
                )
            }
        }
    }

    // MARK: - Helpers

    private func humanBytes(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KiB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MiB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GiB", Double(n) / (1024 * 1024 * 1024))
    }
}
