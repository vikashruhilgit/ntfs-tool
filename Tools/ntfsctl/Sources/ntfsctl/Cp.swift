import ArgumentParser
import Foundation
import NTFSCore
import NTFSOps

/// Copy files / directory trees between host and NTFS volume.
///
/// Default direction is host → volume. Pass `--from-volume` to invert
/// (volume → host: pull files off the NTFS drive onto local disk).
///
/// This command is a FRONT-END only: argument parsing, destination resolution,
/// and progress rendering live here, while the actual copy/move semantics live
/// in `NTFSOps.TransferEngine`, shared with the menu-bar app's file browser.
/// Anything about *how bytes land on the volume* belongs in the engine, so the
/// two front-ends cannot drift apart.
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

    func run() async throws {
        if fromVolume {
            try await runVolumeToHost()
        } else {
            try await runHostToVolume()
        }
    }

    // MARK: - Engine wiring

    private var transferOptions: TransferOptions {
        TransferOptions(
            conflict: noClobber ? .skip : .replace,
            removeSource: move,
            chunkSize: chunkSize
        )
    }

    /// Build an engine whose progress/skip callbacks render this command's
    /// stderr lines. Captured as local `let`s so the closures stay `@Sendable`.
    private func makeEngine(volume: NTFSCore.Volume) -> TransferEngine {
        let showProgress = progress
        let showVerbose = verbose
        return TransferEngine(
            volume: volume,
            options: transferOptions,
            onProgress: { p in
                guard showProgress else { return }
                let pct = String(format: "%.1f", p.fraction * 100)
                let elapsed = String(format: "%.1f", p.elapsed)
                let rate = String(format: "%.1f", p.elapsed > 0 ? Double(p.filesDone) / p.elapsed : 0)
                let counts = "[\(p.filesDone)/\(p.totalFiles)]"
                let bytes = "\(ByteFormat.human(p.bytesDone))/\(ByteFormat.human(p.totalBytes))"
                let line = "\(counts) \(bytes) (\(pct)%) elapsed=\(elapsed)s rate=\(rate)/s - \(p.currentName)\n"
                FileHandle.standardError.write(Data(line.utf8))
            },
            onSkip: { path, reason in
                switch reason {
                case let .notARegularFile(kind):
                    FileHandle.standardError.write(Data("skip \(path): not a regular file (\(kind))\n".utf8))
                case .destinationExists:
                    if showVerbose {
                        FileHandle.standardError.write(Data("skip \(path) → already exists\n".utf8))
                    }
                }
            }
        )
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
        let engine = makeEngine(volume: volume)

        // Resolve where the source lands.
        let endsWithSlash = destination.hasSuffix("/")
        let trimmedDest = destination.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let sourceBasename = (source as NSString).lastPathComponent

        // An empty requested path ("" or "/") maps to the volume root (recnum 5),
        // which always exists and is a directory.
        let resolvedRecnum: UInt64?
        let destIsDir: Bool
        if trimmedDest.isEmpty {
            resolvedRecnum = 5
            destIsDir = true
        } else if let resolved = try await volume.resolvePath(trimmedDest) {
            resolvedRecnum = resolved
            destIsDir = try await engine.isDirectory(resolved)
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

        // Scan the source for totals + the cluster arithmetic the free-space
        // check needs (the raw byte sum understates a tree of small files).
        let plan = try engine.planHostTree(at: source, bytesPerCluster: UInt64(volume.bytesPerCluster))

        if !noFreeCheck {
            do {
                try await engine.assertFreeSpace(for: plan)
            } catch let e as TransferError {
                throw ValidationError((e.errorDescription ?? "\(e)") + " Free up space or copy less; pass --no-free-check to override.")
            }
        }

        let summaryLine = destinationSummaryLine(
            outcome: outcome,
            requested: trimmedDest,
            sourceBasename: sourceBasename
        )
        FileHandle.standardOutput.write(Data((summaryLine + "\n").utf8))

        if dryRun {
            FileHandle.standardOutput.write(Data("DRY-RUN: would copy \(plan.totalFiles) file(s), \(ByteFormat.human(plan.totalBytes)) total\n".utf8))
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
        await engine.begin(plan: plan)
        let cpStart = Date()

        // Move accounting for the single-file case, which the engine's tree
        // walker does not own (the CLI resolved the leaf name itself).
        var singleFileMoved = 0
        var singleFileFreed: UInt64 = 0

        switch outcome {
        case .merge:
            // Merge: the recursion root IS the resolved dest dir, so source's
            // CHILDREN land directly inside it. The planner only returns .merge
            // for dir sources, and only when the destination exists.
            guard let mergeRoot = resolvedRecnum else {
                throw ValidationError("internal: merge outcome without a resolved destination")
            }
            _ = try await engine.copyHostTree(at: source, intoDirectory: mergeRoot)
        case .nest, .new:
            let (destParent, destName) = try await resolveDestination(
                volume: volume,
                engine: engine,
                requested: trimmedDest,
                endsWithSlash: endsWithSlash,
                sourceBasename: sourceBasename
            )
            if srcIsDir.boolValue {
                let dirRN = try await engine.ensureDirectory(inDirectory: destParent, named: destName)
                _ = try await engine.copyHostTree(at: source, intoDirectory: dirRN)
            } else {
                let copied = try await engine.copyHostFile(at: source, intoDirectory: destParent, named: destName)
                // Delete the source ONLY on a true (copied) return. A skip
                // returns false and a failure throws — both leave it intact.
                if move && copied {
                    let size = (try? FileManager.default.attributesOfItem(atPath: source)[.size] as? UInt64) ?? 0
                    try FileManager.default.removeItem(atPath: source)
                    singleFileMoved = 1
                    singleFileFreed = size
                }
            }
        }
        try await volume.endWriteSession()

        let result = await engine.currentSummary
        if move {
            FileHandle.standardError.write(Data(
                "moved: deleted \(result.movedFiles + singleFileMoved) source file(s), freed \(ByteFormat.human(result.freedBytes + singleFileFreed))\n".utf8
            ))
        }
        reportDone(result, since: cpStart)
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
        let displayPath = requested.isEmpty ? "/" : "/\(requested)"
        let moveSuffix = move ? " — moving (source deleted after each file copies)" : ""
        switch outcome {
        case .new:
            return "→ creating \(displayPath) (new)\(moveSuffix)"
        case .nest:
            let nestPath = displayPath == "/" ? "/\(sourceBasename)" : "\(displayPath)/\(sourceBasename)"
            return "→ nesting under \(nestPath) (dest exists; pass -T to merge)\(moveSuffix)"
        case let .merge(conflict):
            return "→ merging into \(displayPath) (existing dir; conflicts: \(conflict.rawValue))\(moveSuffix)"
        }
    }

    private func resolveDestination(
        volume: NTFSCore.Volume,
        engine: TransferEngine,
        requested: String,
        endsWithSlash: Bool,
        sourceBasename: String
    ) async throws -> (UInt64, String) {
        if requested.isEmpty {
            return (5, sourceBasename)
        }
        let components = requested.split(separator: "/").map(String.init)
        if let resolved = try await volume.resolvePath(requested) {
            if try await engine.isDirectory(resolved) {
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
            current = try await engine.ensureDirectory(inDirectory: current, named: comp)
        }
        return (current, leafName)
    }

    // MARK: - Volume → Host (--from-volume)

    private func runVolumeToHost() async throws {
        // --move deletes from the volume after each pull, so the device must be
        // opened writable in that case. Plain pulls stay read-only.
        let blockDevice = move
            ? try FileHandleBlockDevice(openingFileForUpdateAt: device)
            : try FileHandleBlockDevice(openingFileAt: device)
        let volume = try await NTFSCore.Volume(device: blockDevice)
        let engine = makeEngine(volume: volume)

        guard let srcRN = try await volume.resolvePath(source) else {
            throw ValidationError("volume path not found: \(source) (hint: check `ntfsctl list` to confirm the path; case-insensitive on ASCII)")
        }
        let srcIsDir = try await engine.isDirectory(srcRN)
        if srcIsDir && !recursive {
            throw ValidationError("volume source is a directory; pass -r/--recursive")
        }

        let fm = FileManager.default
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

        let plan = try await engine.planVolumeTree(at: srcRN)

        if dryRun {
            FileHandle.standardOutput.write(Data("DRY-RUN: would pull \(plan.totalFiles) file(s), \(ByteFormat.human(plan.totalBytes)) total → \(finalHostPath)\n".utf8))
            if move {
                FileHandle.standardOutput.write(Data(
                    "DRY-RUN: with --move, each successfully-pulled volume source is then deleted (skipped sources preserved); nothing is written or deleted in dry-run\n".utf8
                ))
            }
            return
        }

        // --move mutates the volume (deletes sources), so mark it dirty for the
        // duration like the host→volume path does.
        if move { try await volume.beginWriteSession() }
        await engine.begin(plan: plan)
        let cpStart = Date()

        var singleFileMoved = 0
        var singleFileFreed: UInt64 = 0
        if srcIsDir {
            try fm.createDirectory(atPath: finalHostPath, withIntermediateDirectories: true)
            _ = try await engine.pullTree(at: srcRN, toHostDir: finalHostPath)
        } else {
            let copied = try await engine.pullFile(at: srcRN, toHostPath: finalHostPath, named: sourceBasename)
            if move && copied {
                try await volume.deleteFile(at: srcRN)
                singleFileMoved = 1
                singleFileFreed = plan.totalBytes
            }
        }

        let result = await engine.currentSummary
        if move {
            try await volume.endWriteSession()
            FileHandle.standardError.write(Data(
                "moved: deleted \(result.movedFiles + singleFileMoved) volume source file(s), freed \(ByteFormat.human(result.freedBytes + singleFileFreed))\n".utf8
            ))
        }
        reportDone(result, since: cpStart)
    }

    // MARK: - Helpers

    private func reportDone(_ result: TransferSummary, since start: Date) {
        guard progress || verbose else { return }
        let elapsed = Date().timeIntervalSince(start)
        let fileRate = elapsed > 0 ? Double(result.copiedFiles) / elapsed : 0
        let mibRate = elapsed > 0 ? (Double(result.copiedBytes) / 1_048_576.0) / elapsed : 0
        let counts = "\(result.copiedFiles)/\(result.totalFiles) files"
        let bytes = "\(ByteFormat.human(result.copiedBytes))/\(ByteFormat.human(result.totalBytes))"
        let timing = "elapsed=\(String(format: "%.1f", elapsed))s"
        let rates = "rate=\(String(format: "%.2f", fileRate)) files/s, \(String(format: "%.2f", mibRate)) MiB/s"
        FileHandle.standardError.write(Data("done: \(counts), \(bytes), \(timing), \(rates)\n".utf8))
    }

}
