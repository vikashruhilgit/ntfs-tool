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

            Conflict handling (existing destination files):
              - default      : replace (overwrite the existing file)
              - -n/--no-clobber : skip (leave the existing file untouched)

            Limitations:
              - Symlinks/hardlinks/devnodes in source are skipped (with warning).
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

    @Flag(name: [.customLong("move"), .customLong("remove-source")], help: "Cross-device cut: delete each source file after its copy succeeds (skipped/failed sources are preserved). --remove-source is an alias.")
    var move: Bool = false

    @Flag(name: [.customShort("T"), .long], help: "No-target-directory: when DEST is an existing directory, merge SOURCE's contents into it instead of nesting under DEST/<sourceBasename>.")
    var noTargetDirectory: Bool = false

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

        // Resolve the requested destination path once. An empty requested path
        // (i.e. "" or "/") maps to the volume root (recnum 5), which always
        // exists and is a directory.
        let resolvedRecnum: UInt64?
        let destIsDir: Bool
        if trimmedDest.isEmpty {
            resolvedRecnum = 5
            destIsDir = true
        } else if let resolved = try await volume.resolvePath(trimmedDest) {
            resolvedRecnum = resolved
            destIsDir = try await isDirectory(volume: volume, recnum: resolved)
        } else {
            resolvedRecnum = nil
            destIsDir = false
        }

        // Pure decision: NEW vs NEST vs MERGE + conflict policy.
        let outcome: DestinationOutcome
        do {
            outcome = try DestinationPlan.resolve(
                destExists: resolvedRecnum != nil,
                destIsDirectory: destIsDir,
                sourceIsDirectory: srcIsDir.boolValue,
                noTargetDirectory: noTargetDirectory,
                noClobber: noClobber
            )
        } catch DestinationPlanError.destinationIsFile {
            throw ValidationError("destination already exists as a file: /\(trimmedDest) (pass to a directory ending with '/' to copy under it)")
        }

        // Scan source to build a plan + size totals. `totalBytes` is the raw
        // sum of file sizes (for display/progress); `dataClusters` is what the
        // data streams will ACTUALLY consume on the volume — each file's bytes
        // rounded UP to whole clusters — which is what the free-space check
        // must use, not the raw sum.
        let clusterBytes = UInt64(volume.bytesPerCluster)
        func clustersFor(_ size: UInt64) -> UInt64 { (size + clusterBytes - 1) / clusterBytes }
        var totalFiles = 0
        var totalBytes: UInt64 = 0
        var dataClusters: UInt64 = 0
        if srcIsDir.boolValue {
            try walkHostDir(source) { _, fileSize in
                totalFiles += 1
                totalBytes += fileSize
                dataClusters += clustersFor(fileSize)
            }
        } else {
            totalFiles = 1
            totalBytes = (try fm.attributesOfItem(atPath: source)[.size] as? UInt64) ?? 0
            dataClusters = clustersFor(totalBytes)
        }

        // Free-space pre-check — CONSERVATIVE so the user is stopped UP FRONT
        // rather than failing mid-copy with ENOSPC. Account for:
        //   • data: each file's content rounded up to whole clusters
        //   • $MFT growth: ~1 MFT record per file (recordsPerCluster per cluster)
        //   • $I30 index growth: a per-file allowance for index entries + the
        //     non-resident $INDEX_ALLOCATION blocks large directories need.
        if !noFreeCheck {
            let stats = try await volume.allocationStats()
            let recsPerCluster = max(UInt64(1), clusterBytes / UInt64(volume.mftRecordSizeBytes))
            let mftClusters = (UInt64(totalFiles) + recsPerCluster - 1) / recsPerCluster
            let indexClusters = (UInt64(totalFiles) * 256 + clusterBytes - 1) / clusterBytes  // ~256 B/file, conservative
            let requiredClusters = dataClusters + mftClusters + indexClusters
            let requiredBytes = requiredClusters * clusterBytes
            if requiredClusters > stats.freeClusters {
                throw ValidationError(
                    "insufficient free space: \(totalFiles) file(s) need ~\(humanBytes(requiredBytes)) on the volume "
                    + "(\(humanBytes(totalBytes)) of data, rounded up to whole \(clusterBytes)-byte clusters, plus MFT/index overhead) "
                    + "but only \(humanBytes(stats.freeBytes)) is free. Free up space or copy less; pass --no-free-check to override."
                )
            }
        }

        // Preflight resolved-destination summary (shown in both dry-run and
        // real runs, before any bytes move).
        let summaryLine = destinationSummaryLine(
            outcome: outcome,
            requested: trimmedDest,
            sourceBasename: sourceBasename
        )
        FileHandle.standardOutput.write(Data((summaryLine + "\n").utf8))

        if dryRun {
            FileHandle.standardOutput.write(Data("DRY-RUN: would copy \(totalFiles) file(s), \(humanBytes(totalBytes)) total\n".utf8))
            if move {
                FileHandle.standardOutput.write(Data(
                    "DRY-RUN: with --move, each successfully-copied source is then deleted (skipped sources preserved); nothing is written or deleted in dry-run\n".utf8
                ))
            }
            return
        }

        // Mark the volume dirty for the duration of the copy so a crash leaves
        // Windows aware that chkdsk should scan the volume on next mount.
        try await volume.beginWriteSession()

        // Execute the copy.
        var copiedFiles = 0
        var copiedBytes: UInt64 = 0
        // --move accounting: files whose source was actually deleted, and the
        // sum of those sources' sizes (freed host bytes).
        var movedFiles = 0
        var freedBytes: UInt64 = 0
        // v0.4 perf measurement: capture start time so each progress line +
        // the final summary can report elapsed and throughput. Without this
        // it's impossible to tell whether Phase 1 / Phase 2 perf work
        // actually moved the needle.
        let cpStart = Date()
        switch outcome {
        case .merge:
            // Merge: the recursion root IS the resolved dest dir itself, so
            // source's CHILDREN land directly inside it (source/Android →
            // dest/Android, NOT dest/<sourceBasename>/Android). The planner
            // only returns .merge for dir sources. Per-file conflict policy
            // (skip/replace) is enforced inside copyOneFile via noClobber.
            // .merge is only returned when destExists, so resolvedRecnum is
            // non-nil here; guard rather than force-unwrap to keep the
            // no-crash guarantee local (CLAUDE.md: no fatalError in code).
            guard let mergeRoot = resolvedRecnum else {
                throw ValidationError("internal: merge outcome without a resolved destination")
            }
            try await copyDirectoryRecursive(
                volume: volume,
                hostDir: source,
                ntfsParent: mergeRoot,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                movedFiles: &movedFiles,
                freedBytes: &freedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                startTime: cpStart
            )
        case .nest, .new:
            // For .nest the resolved dir exists → nest under it as
            // <sourceBasename>. For .new the parent is walked/created and the
            // leaf name is taken from the requested path (or sourceBasename
            // for trailing-slash / root). resolveDestination handles both.
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
                    ntfsParent: dirRN,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    movedFiles: &movedFiles,
                    freedBytes: &freedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes,
                    startTime: cpStart
                )
            } else {
                let copied = try await copyOneFile(
                    volume: volume,
                    hostFile: source,
                    ntfsParent: destParent,
                    name: destName,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes,
                    startTime: cpStart
                )
                // --move single-file: delete source ONLY on a true (copied)
                // return. A skip (-n collision / non-regular) returns false and
                // a failure throws — both leave the source intact.
                if move && copied {
                    let size = (try? FileManager.default.attributesOfItem(atPath: source)[.size] as? UInt64) ?? 0
                    try FileManager.default.removeItem(atPath: source)
                    movedFiles += 1
                    freedBytes += size
                }
            }
        }
        try await volume.endWriteSession()

        if move {
            FileHandle.standardError.write(Data(
                "moved: deleted \(movedFiles) source file(s), freed \(humanBytes(freedBytes))\n".utf8
            ))
        }

        if progress || verbose {
            let elapsed = Date().timeIntervalSince(cpStart)
            let fileRate = elapsed > 0 ? Double(copiedFiles) / elapsed : 0
            let mibRate = elapsed > 0 ? (Double(copiedBytes) / 1_048_576.0) / elapsed : 0
            FileHandle.standardError.write(Data(
                "done: \(copiedFiles)/\(totalFiles) files, \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)), elapsed=\(String(format: "%.1f", elapsed))s, rate=\(String(format: "%.2f", fileRate)) files/s, \(String(format: "%.2f", mibRate)) MiB/s\n".utf8
            ))
        }
    }

    /// One-line resolved-destination summary, derived purely from the planner
    /// outcome plus the requested display path string. We deliberately do NOT
    /// reverse-resolve a recnum → path; we show the requested `trimmedDest`
    /// prefixed with '/' (root/empty renders as just "/").
    private func destinationSummaryLine(
        outcome: DestinationOutcome,
        requested: String,
        sourceBasename: String
    ) -> String {
        // Display path: "/" for the root/empty case, "/<requested>" otherwise.
        let displayPath = requested.isEmpty ? "/" : "/\(requested)"
        // --move turns the copy into a cross-device cut: each source is deleted
        // after its own copy succeeds. Surface that in the preflight line.
        let moveSuffix = move ? " — moving (source deleted after each file copies)" : ""
        switch outcome {
        case .new:
            return "→ creating \(displayPath) (new)\(moveSuffix)"
        case .nest:
            // Avoid a double slash when displayPath is the bare root "/".
            let nestPath = displayPath == "/" ? "/\(sourceBasename)" : "\(displayPath)/\(sourceBasename)"
            return "→ nesting under \(nestPath) (dest exists; pass -T to merge)\(moveSuffix)"
        case let .merge(conflict):
            return "→ merging into \(displayPath) (existing dir; conflicts: \(conflict.rawValue))\(moveSuffix)"
        }
    }

    private func walkHostDir(_ root: String, visit: (_ path: String, _ size: UInt64) throws -> Void) throws {
        let fm = FileManager.default
        // Each iteration touches autoreleased Foundation objects (NSString path
        // ops, the attributesOfItem NSDictionary). On a 22k-file tree these
        // would pile up for the whole pre-scan; drain per entry so the walk's
        // peak memory is independent of the file count.
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for name in entries.sorted() {
            let recurseInto: String? = try autoreleasepool {
                let full = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
                if isDir.boolValue {
                    return full
                }
                let size = (try fm.attributesOfItem(atPath: full)[.size] as? UInt64) ?? 0
                try visit(full, size)
                return nil
            }
            if let recurseInto {
                try walkHostDir(recurseInto, visit: visit)
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

    func isDirectory(volume: NTFSCore.Volume, recnum: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        let rec = try await mft.record(at: recnum)
        return rec.isDirectory
    }

    func childRecnum(volume: NTFSCore.Volume, parent: UInt64, name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos &&
            $0.name.lowercased() == needle
        }?.recordNumber
    }

    func ensureDirectory(volume: NTFSCore.Volume, parent: UInt64, name: String) async throws -> UInt64 {
        if let existing = try await childRecnum(volume: volume, parent: parent, name: name) {
            if try await isDirectory(volume: volume, recnum: existing) { return existing }
            throw ValidationError("destination /\(name) exists as a file, refusing to clobber")
        }
        return try await volume.createFile(named: name, inDirectory: parent, isDirectory: true)
    }

    /// Copy one host file into the volume.
    ///
    /// Returns `true` iff the destination write actually happened (the file was
    /// copied). Returns `false` when the file was SKIPPED — either a non-regular
    /// source or a `--no-clobber` collision with an existing destination. A
    /// thrown error means the copy FAILED and propagates so the caller never
    /// treats it as success. Callers gate the `--move` source-delete on a `true`
    /// return only, which guarantees no source is ever deleted speculatively.
    @discardableResult
    func copyOneFile(
        volume: NTFSCore.Volume,
        hostFile: String,
        ntfsParent: UInt64,
        name: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64,
        startTime: Date
    ) async throws -> Bool {
        let url = URL(fileURLWithPath: hostFile)
        // Pull the two attributes we need out of the autoreleased NSDictionary
        // inside a pool so it (and its NSNumber/NSString values) are reclaimed
        // immediately rather than accumulating across every file in a cp -r.
        let (fileType, size): (FileAttributeType?, UInt64) = try autoreleasepool {
            let attrs = try FileManager.default.attributesOfItem(atPath: hostFile)
            return (attrs[.type] as? FileAttributeType, attrs[.size] as? UInt64 ?? 0)
        }
        if let type = fileType, type != .typeRegular {
            FileHandle.standardError.write(Data("skip \(hostFile): not a regular file (\(type.rawValue))\n".utf8))
            return false
        }
        if let existing = try await childRecnum(volume: volume, parent: ntfsParent, name: name) {
            if noClobber {
                if verbose { FileHandle.standardError.write(Data("skip \(hostFile) → already exists\n".utf8)) }
                return false
            }
            try await volume.deleteFile(at: existing)
        }
        // Pass the size so the $I30 index entry carries it — Windows Explorer
        // reads file size from there (0 → shows 0 KB and refuses to open).
        let rn = try await volume.createFile(named: name, inDirectory: ntfsParent, isDirectory: false, dataSize: size)
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
            let elapsed = Date().timeIntervalSince(startTime)
            let fileRate = elapsed > 0 ? Double(copiedFiles) / elapsed : 0
            FileHandle.standardError.write(Data(
                "[\(copiedFiles)/\(totalFiles)] \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)) (\(String(format: "%.1f", pct))%) elapsed=\(String(format: "%.1f", elapsed))s rate=\(String(format: "%.1f", fileRate))/s - \(name)\n".utf8
            ))
        }
        return true
    }

    /// Copy a host directory tree into the volume.
    ///
    /// Returns `fullyMoved`: `true` iff EVERY child file was copied AND every
    /// child subdir also returned `fullyMoved`. A directory that still holds a
    /// skipped/failed child reports `false`, which propagates up so no ancestor
    /// source directory is removed under `--move`. When `move` is set and this
    /// directory ended up fully moved (hence empty), its emptied host source dir
    /// is removed depth-first AFTER its children — never before.
    @discardableResult
    func copyDirectoryRecursive(
        volume: NTFSCore.Volume,
        hostDir: String,
        ntfsParent: UInt64,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        movedFiles: inout Int,
        freedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64,
        startTime: Date
    ) async throws -> Bool {
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
            autoreleasepool {
                let fullPath = (hostDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return }
                if isDir.boolValue {
                    subdirs.append((name, fullPath))
                } else {
                    files.append((name, fullPath))
                }
            }
        }

        // Track whether every child of THIS directory was fully moved. Any
        // skip (or a subdir that itself wasn't fully moved) flips this false,
        // which both blocks this dir's own removal and propagates to the
        // caller so ancestor source dirs are also preserved.
        var fullyMoved = true

        // 1) Recurse into subdirs first. Each recursion may open its own
        //    bulk-insert window at the child level — that's fine because
        //    THIS level's window is still closed.
        for (name, fullPath) in subdirs {
            let childRN = try await ensureDirectory(volume: volume, parent: ntfsParent, name: name)
            let childFullyMoved = try await copyDirectoryRecursive(
                volume: volume,
                hostDir: fullPath,
                ntfsParent: childRN,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                movedFiles: &movedFiles,
                freedBytes: &freedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                startTime: startTime
            )
            if !childFullyMoved { fullyMoved = false }
        }

        // 2) Now copy this level's files inside one bulk-insert window.
        //    Per-file refreshParentI30Size calls become no-ops; size hints
        //    will show as 0 in Windows Explorer until a subsequent write
        //    or explicit hint-refresh updates them. File contents are
        //    byte-correct on disk.
        if !files.isEmpty {
            try await volume.beginBulkInsert(into: ntfsParent)
            do {
                for (name, fullPath) in files {
                    let copied = try await copyOneFile(
                        volume: volume,
                        hostFile: fullPath,
                        ntfsParent: ntfsParent,
                        name: name,
                        copiedFiles: &copiedFiles,
                        copiedBytes: &copiedBytes,
                        totalFiles: totalFiles,
                        totalBytes: totalBytes,
                        startTime: startTime
                    )
                    if copied {
                        // --move: delete the source file ONLY after its copy
                        // returned success. Per-file, AFTER the write — never
                        // speculatively. A throw above would have propagated,
                        // leaving the source intact.
                        if move {
                            let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? UInt64) ?? 0
                            try FileManager.default.removeItem(atPath: fullPath)
                            movedFiles += 1
                            freedBytes += size
                        }
                    } else {
                        // Skipped (no-clobber collision or non-regular): source
                        // preserved, and this dir is no longer fully moved.
                        fullyMoved = false
                    }
                }
                _ = try await volume.endBulkInsert()
            } catch {
                _ = try? await volume.endBulkInsert()
                throw error
            }
        }

        // 3) Depth-first dir cleanup: only remove the emptied source dir once
        //    every child (files + subdirs) was moved. If anything was skipped
        //    or a subdir wasn't fully moved, leave this dir in place.
        if move && fullyMoved {
            try FileManager.default.removeItem(atPath: hostDir)
            if verbose {
                FileHandle.standardError.write(Data("rm-dir \(hostDir) (emptied by --move)\n".utf8))
            }
        }
        return fullyMoved
    }

    // MARK: - Volume → Host (--from-volume)

    private func runVolumeToHost() async throws {
        // --move deletes from the volume after each pull, so the device must be
        // opened writable in that case. Plain pulls stay read-only.
        let blockDevice = move
            ? try FileHandleBlockDevice(openingFileForUpdateAt: device)
            : try FileHandleBlockDevice(openingFileAt: device)
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
            if move {
                FileHandle.standardOutput.write(Data(
                    "DRY-RUN: with --move, each successfully-pulled volume source is then deleted (skipped sources preserved); nothing is written or deleted in dry-run\n".utf8
                ))
            }
            return
        }

        // --move on the volume→host path mutates the volume (deletes sources),
        // so mark it dirty for the duration like the host→volume path does.
        if move { try await volume.beginWriteSession() }

        var copiedFiles = 0
        var copiedBytes: UInt64 = 0
        var movedFiles = 0
        var freedBytes: UInt64 = 0
        let cpStart = Date()
        if srcIsDir {
            try fm.createDirectory(atPath: finalHostPath, withIntermediateDirectories: true)
            try await pullDirRecursive(
                volume: volume,
                volumeDirRN: srcRN,
                hostDir: finalHostPath,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                movedFiles: &movedFiles,
                freedBytes: &freedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                startTime: cpStart
            )
        } else {
            let copied = try await pullOneFile(
                volume: volume,
                rn: srcRN,
                hostPath: finalHostPath,
                fileName: sourceBasename,
                copiedFiles: &copiedFiles,
                copiedBytes: &copiedBytes,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                startTime: cpStart
            )
            // --move single-file: delete the volume source ONLY on a true
            // (pulled) return. deleteFile is extension-record-aware (PR #24).
            if move && copied {
                try await volume.deleteFile(at: srcRN)
                movedFiles += 1
                freedBytes += totalBytes
            }
        }

        if move {
            try await volume.endWriteSession()
            FileHandle.standardError.write(Data(
                "moved: deleted \(movedFiles) volume source file(s), freed \(humanBytes(freedBytes))\n".utf8
            ))
        }

        if progress || verbose {
            let elapsed = Date().timeIntervalSince(cpStart)
            let fileRate = elapsed > 0 ? Double(copiedFiles) / elapsed : 0
            let mibRate = elapsed > 0 ? (Double(copiedBytes) / 1_048_576.0) / elapsed : 0
            FileHandle.standardError.write(Data(
                "done: \(copiedFiles)/\(totalFiles) files, \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)), elapsed=\(String(format: "%.1f", elapsed))s, rate=\(String(format: "%.2f", fileRate)) files/s, \(String(format: "%.2f", mibRate)) MiB/s\n".utf8
            ))
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

    /// Pull one volume file onto the host.
    ///
    /// Returns `true` iff the destination write actually happened. Returns
    /// `false` when SKIPPED (`--no-clobber` and the host destination exists). A
    /// thrown error means the pull FAILED and propagates so the caller never
    /// treats it as success. Callers gate the `--move` volume-source delete on a
    /// `true` return only — no source is ever deleted speculatively.
    @discardableResult
    private func pullOneFile(
        volume: NTFSCore.Volume,
        rn: UInt64,
        hostPath: String,
        fileName: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64,
        startTime: Date
    ) async throws -> Bool {
        let fm = FileManager.default
        if noClobber && fm.fileExists(atPath: hostPath) {
            if verbose { FileHandle.standardError.write(Data("skip \(hostPath) → already exists\n".utf8)) }
            return false
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
            // Drain the autorelease pool around the host write — `write(contentsOf:)`
            // bridges to NSData, which would otherwise accumulate one buffer per
            // chunk for the whole `cp -r --from-volume`, the OOM-mid-copy failure mode.
            try autoreleasepool { try handle.write(contentsOf: data) }
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
            let elapsed = Date().timeIntervalSince(startTime)
            let fileRate = elapsed > 0 ? Double(copiedFiles) / elapsed : 0
            FileHandle.standardError.write(Data(
                "[\(copiedFiles)/\(totalFiles)] \(humanBytes(copiedBytes))/\(humanBytes(totalBytes)) (\(String(format: "%.1f", pct))%) elapsed=\(String(format: "%.1f", elapsed))s rate=\(String(format: "%.1f", fileRate))/s - \(fileName)\n".utf8
            ))
        }
        return true
    }

    /// Pull a volume directory tree onto the host.
    ///
    /// Returns `fullyMoved`: `true` iff every child file was pulled AND every
    /// child subdir returned `fullyMoved`. Under `--move`, after children are
    /// moved depth-first, an emptied volume source dir is deleted via
    /// `volume.deleteFile` (which removes the dir record + its parent $I30
    /// entry; children were already removed so nothing dangles). A subdir that
    /// wasn't fully moved blocks its own and its ancestors' removal.
    @discardableResult
    private func pullDirRecursive(
        volume: NTFSCore.Volume,
        volumeDirRN: UInt64,
        hostDir: String,
        copiedFiles: inout Int,
        copiedBytes: inout UInt64,
        movedFiles: inout Int,
        freedBytes: inout UInt64,
        totalFiles: Int,
        totalBytes: UInt64,
        startTime: Date
    ) async throws -> Bool {
        let fm = FileManager.default
        let entries = try await volume.enumerate(directory: volumeDirRN)
        var fullyMoved = true
        for e in entries where e.fileName.namespace != .dos {
            let hostChild = (hostDir as NSString).appendingPathComponent(e.name)
            if e.isDirectory {
                try fm.createDirectory(atPath: hostChild, withIntermediateDirectories: true)
                let childFullyMoved = try await pullDirRecursive(
                    volume: volume,
                    volumeDirRN: e.recordNumber,
                    hostDir: hostChild,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    movedFiles: &movedFiles,
                    freedBytes: &freedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes,
                    startTime: startTime
                )
                if !childFullyMoved { fullyMoved = false }
            } else {
                let size = e.fileName.realSize
                let copied = try await pullOneFile(
                    volume: volume,
                    rn: e.recordNumber,
                    hostPath: hostChild,
                    fileName: e.name,
                    copiedFiles: &copiedFiles,
                    copiedBytes: &copiedBytes,
                    totalFiles: totalFiles,
                    totalBytes: totalBytes,
                    startTime: startTime
                )
                if copied {
                    // --move: delete the volume source file ONLY after its pull
                    // succeeded. deleteFile is extension-record-aware (PR #24).
                    if move {
                        try await volume.deleteFile(at: e.recordNumber)
                        movedFiles += 1
                        freedBytes += size
                    }
                } else {
                    fullyMoved = false
                }
            }
        }
        // Depth-first dir cleanup: remove the emptied volume source dir only
        // when every child moved. deleteFile works on a now-empty directory
        // record (no empty-check required; children were removed above).
        if move && fullyMoved {
            try await volume.deleteFile(at: volumeDirRN)
            if verbose {
                FileHandle.standardError.write(Data("rm-dir volume recnum \(volumeDirRN) (emptied by --move)\n".utf8))
            }
        }
        return fullyMoved
    }

    // MARK: - Helpers

    private func humanBytes(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KiB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MiB", Double(n) / (1024 * 1024)) }
        return String(format: "%.2f GiB", Double(n) / (1024 * 1024 * 1024))
    }
}
