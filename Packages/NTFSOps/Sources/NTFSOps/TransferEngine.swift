import Foundation
import NTFSCore

/// The single copy/move engine for the project.
///
/// Both front-ends drive this type: `ntfsctl cp` wraps it with argument parsing
/// and stderr progress lines, and the menu-bar file browser wraps it with a
/// progress sheet. Keeping one engine means the transfer semantics that Windows
/// `chkdsk` validated at v0.7.4 — size-carrying `$I30` entries, bulk-insert
/// windows, per-file source deletion under move — cannot drift between them.
///
/// **Cancellation** is standard Swift task cancellation. The engine checks at
/// every file boundary and between content chunks, so a cancelled transfer stops
/// within one chunk (1 MiB by default) rather than at the end of the file. A
/// cancelled run leaves the volume structurally consistent: whatever files
/// completed are fully written and indexed, and the in-flight file is either
/// fully written or removed. `summary` then reports what actually landed.
///
/// **Progress** is a callback invoked after each file completes. It is
/// `@Sendable` and may be called from the engine's executor, so a UI consumer
/// must hop to the main actor itself.
public actor TransferEngine {
    private let volume: Volume
    private let options: TransferOptions
    private let onProgress: (@Sendable (TransferProgress) -> Void)?
    private let onSkip: (@Sendable (String, SkipReason) -> Void)?

    private var summary = TransferSummary()
    private var startedAt = Date()

    public init(
        volume: Volume,
        options: TransferOptions = TransferOptions(),
        onProgress: (@Sendable (TransferProgress) -> Void)? = nil,
        onSkip: (@Sendable (String, SkipReason) -> Void)? = nil
    ) {
        self.volume = volume
        self.options = options
        self.onProgress = onProgress
        self.onSkip = onSkip
    }

    /// Counters as of right now. Read this after a `CancellationError` to report
    /// the partial result.
    public var currentSummary: TransferSummary { summary }

    // MARK: - Planning

    /// Walk a host tree and total it up without moving any bytes.
    public nonisolated func planHostTree(at path: String, bytesPerCluster: UInt64) throws -> TransferPlan {
        var files = 0
        var bytes: UInt64 = 0
        var clusters: UInt64 = 0
        func account(_ size: UInt64) {
            files += 1
            bytes += size
            clusters += (size + bytesPerCluster - 1) / bytesPerCluster
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw TransferError.sourceNotFound(path)
        }
        if isDir.boolValue {
            try Self.walkHostDir(path) { _, size in account(size) }
        } else {
            account((try fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0)
        }
        return TransferPlan(totalFiles: files, totalBytes: bytes, dataClusters: clusters)
    }

    /// Walk a volume subtree and total it up. Directories contribute no bytes.
    public func planVolumeTree(at recordNumber: UInt64) async throws -> TransferPlan {
        var files = 0
        var bytes: UInt64 = 0
        if try await isDirectory(recordNumber) {
            try await walkVolumeDir(recordNumber) { _, size, _ in
                files += 1
                bytes += size
            }
        } else {
            files = 1
            bytes = try await fileSize(of: recordNumber)
        }
        return TransferPlan(totalFiles: files, totalBytes: bytes, dataClusters: 0)
    }

    /// Conservative up-front free-space check, so the user is stopped BEFORE a
    /// long copy rather than failing with ENOSPC at 80%.
    ///
    /// Accounts for three consumers, not just file data:
    ///   * data — each file rounded up to whole clusters
    ///   * `$MFT` growth — roughly one MFT record per file
    ///   * `$I30` growth — a per-file allowance for index entries and the
    ///     non-resident `$INDEX_ALLOCATION` blocks that large directories need
    public func assertFreeSpace(for plan: TransferPlan) async throws {
        let clusterBytes = UInt64(volume.bytesPerCluster)
        let stats = try await volume.allocationStats()
        let recsPerCluster = max(UInt64(1), clusterBytes / UInt64(volume.mftRecordSizeBytes))
        let mftClusters = (UInt64(plan.totalFiles) + recsPerCluster - 1) / recsPerCluster
        let indexClusters = (UInt64(plan.totalFiles) * 256 + clusterBytes - 1) / clusterBytes
        let required = plan.dataClusters + mftClusters + indexClusters
        if required > stats.freeClusters {
            throw TransferError.insufficientFreeSpace(
                requiredBytes: required * clusterBytes,
                freeBytes: stats.freeBytes,
                files: plan.totalFiles
            )
        }
    }

    /// Seed the totals a progress callback divides by, and start the clock.
    public func begin(plan: TransferPlan) {
        summary = TransferSummary()
        summary.totalFiles = plan.totalFiles
        summary.totalBytes = plan.totalBytes
        startedAt = Date()
    }

    // MARK: - Host → volume

    /// Copy one host file into a volume directory.
    ///
    /// Returns `true` only when the destination write actually happened. A
    /// `false` return means SKIPPED (non-regular source, or a `.skip` conflict);
    /// a throw means FAILED. Callers gate the move-mode source deletion on a
    /// `true` return, which is what guarantees no source is ever deleted
    /// speculatively.
    @discardableResult
    public func copyHostFile(
        at hostPath: String,
        intoDirectory parent: UInt64,
        named name: String
    ) async throws -> Bool {
        try Task.checkCancellation()

        // Read the two attributes we need inside a pool: `attributesOfItem`
        // returns an autoreleased NSDictionary whose NSNumber/NSString values
        // would otherwise accumulate across every file of a recursive copy.
        let (fileType, size): (FileAttributeType?, UInt64) = try autoreleasepool {
            let attrs = try FileManager.default.attributesOfItem(atPath: hostPath)
            return (attrs[.type] as? FileAttributeType, attrs[.size] as? UInt64 ?? 0)
        }
        if let type = fileType, type != .typeRegular {
            summary.skippedFiles += 1
            onSkip?(hostPath, .notARegularFile(type.rawValue))
            return false
        }

        if let existing = try await childRecordNumber(inDirectory: parent, named: name) {
            if options.conflict == .skip {
                summary.skippedFiles += 1
                onSkip?(hostPath, .destinationExists)
                return false
            }
            try await volume.deleteFile(at: existing)
        }

        // Pass the size at create time so the parent's `$I30` entry carries it.
        // Windows Explorer reads file size from the index entry, not the MFT
        // record — a zero there shows "0 KB" and refuses to open the file.
        let rn = try await volume.createFile(
            named: name,
            inDirectory: parent,
            isDirectory: false,
            dataSize: size
        )
        if size > 0 {
            try await volume.writeFile(
                at: rn,
                fromFileAt: URL(fileURLWithPath: hostPath),
                chunkSize: options.chunkSize
            )
        }

        summary.copiedFiles += 1
        summary.copiedBytes += size
        report(name)
        return true
    }

    /// Copy a host directory's CONTENTS into an existing volume directory
    /// (merge semantics — the caller creates or resolves the destination).
    ///
    /// Returns `fullyMoved`: true only when every child file copied and every
    /// child subdirectory also reported true. Any skip propagates false upward,
    /// which is what stops move-mode from removing an ancestor source directory
    /// that still holds a skipped file.
    @discardableResult
    public func copyHostTree(
        at hostDir: String,
        intoDirectory parent: UInt64
    ) async throws -> Bool {
        try Task.checkCancellation()
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: hostDir)) ?? []

        var subdirs: [(name: String, path: String)] = []
        var files: [(name: String, path: String)] = []
        for name in entries.sorted() {
            autoreleasepool {
                let full = (hostDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return }
                if isDir.boolValue {
                    subdirs.append((name, full))
                } else {
                    files.append((name, full))
                }
            }
        }

        var fullyMoved = true

        // Recurse FIRST. Each child opens its own bulk-insert window, and
        // Volume rejects nested begin/end — so this level's window must stay
        // closed until every child has finished.
        for (name, path) in subdirs {
            let childRN = try await ensureDirectory(inDirectory: parent, named: name)
            let childFullyMoved = try await copyHostTree(at: path, intoDirectory: childRN)
            if !childFullyMoved { fullyMoved = false }
        }

        // Then this level's files, under one bulk-insert window.
        if !files.isEmpty {
            try await volume.beginBulkInsert(into: parent)
            do {
                for (name, path) in files {
                    let copied = try await copyHostFile(at: path, intoDirectory: parent, named: name)
                    if copied {
                        if options.removeSource {
                            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                            try fm.removeItem(atPath: path)
                            summary.movedFiles += 1
                            summary.freedBytes += size
                        }
                    } else {
                        fullyMoved = false
                    }
                }
                _ = try await volume.endBulkInsert()
            } catch {
                // Always close the window — including on cancellation — so the
                // volume is not left mid-bulk-insert.
                _ = try? await volume.endBulkInsert()
                if error is CancellationError { summary.cancelled = true }
                throw error
            }
        }

        // Depth-first cleanup: remove the emptied source directory only once
        // every child actually moved.
        if options.removeSource && fullyMoved {
            try fm.removeItem(atPath: hostDir)
        }
        return fullyMoved
    }

    // MARK: - Volume → host

    /// Pull one volume file onto the host. Same true/false/throw contract as
    /// `copyHostFile`.
    @discardableResult
    public func pullFile(
        at recordNumber: UInt64,
        toHostPath hostPath: String,
        named name: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        let fm = FileManager.default
        if options.conflict == .skip && fm.fileExists(atPath: hostPath) {
            summary.skippedFiles += 1
            onSkip?(hostPath, .destinationExists)
            return false
        }
        fm.createFile(atPath: hostPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: hostPath) else {
            throw TransferError.cannotOpenHostFile(hostPath)
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var written: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let data = try await volume.readFileSlice(at: recordNumber, offset: offset, length: options.chunkSize)
            if data.isEmpty { break }
            // `write(contentsOf:)` bridges to NSData; without draining here one
            // buffer per chunk accumulates for the whole pull — the OOM-mid-copy
            // failure mode fixed in the large-transfer work.
            try autoreleasepool { try handle.write(contentsOf: data) }
            offset += UInt64(data.count)
            written += UInt64(data.count)
            if data.count < options.chunkSize { break }
        }

        summary.copiedFiles += 1
        summary.copiedBytes += written
        report(name)
        return true
    }

    /// Pull a volume directory's contents onto the host. Same `fullyMoved`
    /// contract as `copyHostTree`.
    @discardableResult
    public func pullTree(
        at recordNumber: UInt64,
        toHostDir hostDir: String
    ) async throws -> Bool {
        try Task.checkCancellation()
        let fm = FileManager.default
        let entries = try await volume.enumerate(directory: recordNumber)
        var fullyMoved = true

        for e in entries where e.fileName.namespace != .dos {
            let hostChild = (hostDir as NSString).appendingPathComponent(e.name)
            if e.isDirectory {
                try fm.createDirectory(atPath: hostChild, withIntermediateDirectories: true)
                let childFullyMoved = try await pullTree(at: e.recordNumber, toHostDir: hostChild)
                if !childFullyMoved { fullyMoved = false }
            } else {
                let size = e.fileName.realSize
                let copied = try await pullFile(at: e.recordNumber, toHostPath: hostChild, named: e.name)
                if copied {
                    if options.removeSource {
                        try await volume.deleteFile(at: e.recordNumber)
                        summary.movedFiles += 1
                        summary.freedBytes += size
                    }
                } else {
                    fullyMoved = false
                }
            }
        }

        if options.removeSource && fullyMoved {
            // Children are already gone, so the directory record deletes cleanly
            // together with its parent `$I30` entry.
            try await volume.deleteFile(at: recordNumber)
        }
        return fullyMoved
    }

    // MARK: - Delete

    /// Recursively delete a volume subtree, depth-first, reporting progress per
    /// file. Deleting a directory before its children would orphan them, so
    /// children always go first.
    public func deleteTree(at recordNumber: UInt64) async throws {
        try Task.checkCancellation()
        if try await isDirectory(recordNumber) {
            let entries = try await volume.enumerate(directory: recordNumber)
            for e in entries where e.fileName.namespace != .dos {
                try await deleteTree(at: e.recordNumber)
            }
        }
        let name = try await displayName(of: recordNumber)
        try await volume.deleteFile(at: recordNumber)
        summary.copiedFiles += 1
        report(name)
    }

    // MARK: - Shared helpers

    public func isDirectory(_ recordNumber: UInt64) async throws -> Bool {
        let mft = await volume.mft()
        return try await mft.record(at: recordNumber).isDirectory
    }

    /// Case-insensitive child lookup that ignores DOS short-name aliases, so a
    /// file is never matched twice under its 8.3 alias.
    public func childRecordNumber(inDirectory parent: UInt64, named name: String) async throws -> UInt64? {
        let entries = try await volume.enumerate(directory: parent)
        let needle = name.lowercased()
        return entries.first {
            $0.fileName.namespace != .dos && $0.name.lowercased() == needle
        }?.recordNumber
    }

    /// Resolve a child directory, creating it when absent. Throws rather than
    /// clobbering when the name exists as a file.
    public func ensureDirectory(inDirectory parent: UInt64, named name: String) async throws -> UInt64 {
        if let existing = try await childRecordNumber(inDirectory: parent, named: name) {
            if try await isDirectory(existing) { return existing }
            throw TransferError.destinationIsExistingFile(name)
        }
        return try await volume.createFile(named: name, inDirectory: parent, isDirectory: true)
    }

    private func fileSize(of recordNumber: UInt64) async throws -> UInt64 {
        let mft = await volume.mft()
        let attrs = try await mft.record(at: recordNumber).attributes()
        guard let d = attrs.first(where: { $0.type == .data && $0.nameOrEmpty == "" }) else { return 0 }
        switch d.value {
        case let .resident(bytes, _): return UInt64(bytes.count)
        case let .nonResident(_, _, _, _, _, realSize, _, _): return realSize
        }
    }

    private func displayName(of recordNumber: UInt64) async throws -> String {
        let mft = await volume.mft()
        let attrs = try await mft.record(at: recordNumber).attributes()
        for attr in attrs where attr.type == .fileName {
            if case let .resident(bytes, _) = attr.value,
               let fn = try? FileName.parse(bytes),
               fn.namespace != .dos {
                return fn.name
            }
        }
        return "record \(recordNumber)"
    }

    private func walkVolumeDir(
        _ recordNumber: UInt64,
        visit: (UInt64, UInt64, String) async throws -> Void
    ) async throws {
        let entries = try await volume.enumerate(directory: recordNumber)
        for e in entries where e.fileName.namespace != .dos {
            if e.isDirectory {
                try await walkVolumeDir(e.recordNumber, visit: visit)
            } else {
                try await visit(e.recordNumber, e.fileName.realSize, e.name)
            }
        }
    }

    private nonisolated static func walkHostDir(
        _ root: String,
        visit: (_ path: String, _ size: UInt64) throws -> Void
    ) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for name in entries.sorted() {
            // Drain per entry so a 22k-file pre-scan's peak memory stays flat.
            let recurseInto: String? = try autoreleasepool {
                let full = (root as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { return nil }
                if isDir.boolValue { return full }
                try visit(full, (try fm.attributesOfItem(atPath: full)[.size] as? UInt64) ?? 0)
                return nil
            }
            if let recurseInto {
                try walkHostDir(recurseInto, visit: visit)
            }
        }
    }

    private func report(_ name: String) {
        guard let onProgress else { return }
        onProgress(
            TransferProgress(
                filesDone: summary.copiedFiles,
                totalFiles: summary.totalFiles,
                bytesDone: summary.copiedBytes,
                totalBytes: summary.totalBytes,
                currentName: name,
                startedAt: startedAt
            )
        )
    }
}
