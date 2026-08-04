import Foundation
import NTFSCore
import NTFSOps

/// One row in the browser list.
public struct BrowserEntry: Identifiable, Equatable, Sendable {
    public let recordNumber: UInt64
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modified: Date?

    public var id: UInt64 { recordNumber }

    public init(recordNumber: UInt64, name: String, isDirectory: Bool, size: UInt64, modified: Date?) {
        self.recordNumber = recordNumber
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// Directories sort before files, then case-insensitively by name — the
    /// ordering Finder and Explorer both use. Deliberately NOT the on-disk
    /// `$I30` order, which is `$UpCase` collation and looks arbitrary to a user.
    public static func displayOrder(_ a: BrowserEntry, _ b: BrowserEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}

/// A step in the location bar.
public struct BrowserCrumb: Identifiable, Equatable, Sendable {
    public let recordNumber: UInt64
    public let name: String
    public var id: UInt64 { recordNumber }
}

/// What the user has staged with Copy or Cut.
public struct ClipboardContents: Equatable, Sendable {
    public enum Mode: Sendable, Equatable { case copy, cut }
    public let mode: Mode
    public let entries: [BrowserEntry]
    /// Directory the items were taken from — needed so a paste into the SAME
    /// directory can be rejected rather than silently duplicating or, worse,
    /// deleting the source under cut.
    public let sourceDirectory: UInt64

    public var isEmpty: Bool { entries.isEmpty }
}

/// A running operation, surfaced to the progress sheet.
public struct OperationState: Equatable, Sendable {
    public enum Kind: String, Sendable { case copy = "Copying", move = "Moving", delete = "Deleting" }
    public var kind: Kind
    public var filesDone: Int
    public var totalFiles: Int
    public var bytesDone: UInt64
    public var totalBytes: UInt64
    public var currentName: String
    public var fraction: Double
    public var detail: String
}

/// Drives the file browser: directory listing, navigation, clipboard, and the
/// copy / move / delete / format actions.
///
/// All NTFS work is delegated to `NTFSOps.TransferEngine` — this type owns no
/// filesystem logic of its own, matching the project rule that the GUI is an
/// orchestration layer. `@MainActor` so `@Published` state drives SwiftUI
/// directly; engine work runs off-main and hops back here to publish.
@MainActor
public final class FileBrowserModel: ObservableObject {

    @Published public private(set) var entries: [BrowserEntry] = []
    @Published public private(set) var crumbs: [BrowserCrumb] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public var selection: Set<UInt64> = []
    @Published public private(set) var clipboard: ClipboardContents?
    @Published public private(set) var operation: OperationState?
    /// Set when the last operation finished with something worth reporting —
    /// skipped files, or a cancellation that left a partial result.
    @Published public private(set) var lastResultNote: String?

    /// Whether the device was opened read-write. A read-only open (no
    /// permission, or a deliberate safe mode) disables every mutating action so
    /// the UI can't offer something that will fail.
    @Published public private(set) var isWritable = false

    public let devicePath: String
    private var volume: Volume?
    private var currentDirectory: UInt64 = 5
    private var runningTask: Task<Void, Never>?

    /// Injection seam for tests: supply an already-open volume instead of
    /// opening `devicePath`.
    private let volumeProvider: (@Sendable (_ writable: Bool) async throws -> Volume)?

    public init(
        devicePath: String,
        volumeProvider: (@Sendable (_ writable: Bool) async throws -> Volume)? = nil
    ) {
        self.devicePath = devicePath
        self.volumeProvider = volumeProvider
    }

    // MARK: - Opening and listing

    /// Open the device and list the root. Tries read-write first and silently
    /// falls back to read-only — a raw device node is `root:operator 0640`, so
    /// an unprivileged app gets EACCES and should still be able to BROWSE a
    /// device it can read rather than showing nothing at all.
    public func open() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let (vol, writable) = try await openVolume()
            volume = vol
            isWritable = writable
            currentDirectory = 5
            crumbs = [BrowserCrumb(recordNumber: 5, name: "/")]
            await reload()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func openVolume() async throws -> (Volume, Bool) {
        if let volumeProvider {
            return ((try await volumeProvider(true)), true)
        }
        let path = devicePath
        do {
            let device = try FileHandleBlockDevice(openingFileForUpdateAt: path)
            return (try await Volume(device: device), true)
        } catch {
            // Fall back to a read-only open so browsing still works; mutating
            // actions stay disabled via `isWritable`.
            let device = try FileHandleBlockDevice(openingFileAt: path)
            return (try await Volume(device: device), false)
        }
    }

    /// Re-read the current directory. Called after every mutation so the list
    /// reflects on-disk state rather than an optimistic local edit — the volume
    /// is the source of truth.
    public func reload() async {
        guard let volume else { return }
        do {
            let dir = currentDirectory
            let raw = try await volume.enumerate(directory: dir)
            var rows: [BrowserEntry] = []
            rows.reserveCapacity(raw.count)
            for e in raw where e.fileName.namespace != .dos {
                // "." is the directory's own self-reference; showing it would
                // let the user navigate into an infinite chain of itself.
                if e.name == "." { continue }
                rows.append(
                    BrowserEntry(
                        recordNumber: e.recordNumber,
                        name: e.name,
                        isDirectory: e.isDirectory,
                        size: e.fileName.realSize,
                        modified: e.fileName.modificationTime
                    )
                )
            }
            entries = rows.sorted(by: BrowserEntry.displayOrder)
            // Drop selections that no longer exist (deleted, or renamed away).
            let live = Set(entries.map(\.recordNumber))
            selection = selection.intersection(live)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Navigation

    public func enter(_ entry: BrowserEntry) async {
        guard entry.isDirectory else { return }
        currentDirectory = entry.recordNumber
        crumbs.append(BrowserCrumb(recordNumber: entry.recordNumber, name: entry.name))
        selection = []
        await reload()
    }

    /// Jump to a crumb, truncating everything after it.
    public func navigate(to crumb: BrowserCrumb) async {
        guard let idx = crumbs.firstIndex(of: crumb) else { return }
        crumbs = Array(crumbs.prefix(through: idx))
        currentDirectory = crumb.recordNumber
        selection = []
        await reload()
    }

    public func goUp() async {
        guard crumbs.count > 1 else { return }
        crumbs.removeLast()
        if let last = crumbs.last {
            currentDirectory = last.recordNumber
            selection = []
            await reload()
        }
    }

    // MARK: - Clipboard

    public func copySelection() {
        stage(.copy)
    }

    public func cutSelection() {
        guard isWritable else { return }
        stage(.cut)
    }

    private func stage(_ mode: ClipboardContents.Mode) {
        let picked = entries.filter { selection.contains($0.recordNumber) }
        guard !picked.isEmpty else { return }
        clipboard = ClipboardContents(mode: mode, entries: picked, sourceDirectory: currentDirectory)
    }

    public func clearClipboard() {
        clipboard = nil
    }

    /// Whether Paste is currently legal, and why not when it isn't. Returned as
    /// a message rather than a bool so the UI can explain a disabled action.
    public func pasteBlockedReason() -> String? {
        guard isWritable else { return "This volume is open read-only." }
        guard let clipboard, !clipboard.isEmpty else { return "Nothing to paste." }
        if clipboard.sourceDirectory == currentDirectory {
            return clipboard.mode == .cut
                ? "These items are already in this folder."
                : "Pasting into the same folder would need a new name — not supported yet."
        }
        // Moving a folder into its own descendant would detach the subtree from
        // the root; block it up front rather than corrupting the tree.
        if clipboard.mode == .cut {
            let movingDirs = clipboard.entries.filter(\.isDirectory).map(\.recordNumber)
            if crumbs.contains(where: { movingDirs.contains($0.recordNumber) }) {
                return "You can't move a folder into itself."
            }
        }
        return nil
    }

    // MARK: - Operations

    /// Copy or move the clipboard contents into the current directory.
    public func paste() {
        guard pasteBlockedReason() == nil, let clipboard, let volume else { return }
        let destination = currentDirectory
        let isCut = clipboard.mode == .cut
        let items = clipboard.entries

        run(kind: isCut ? .move : .copy) { publish in
            let engine = TransferEngine(
                volume: volume,
                options: TransferOptions(conflict: .replace, removeSource: isCut),
                onProgress: publish
            )

            // Total the whole selection up front so one progress bar spans the
            // batch instead of restarting per item.
            var totalFiles = 0
            var totalBytes: UInt64 = 0
            for item in items {
                let plan = try await engine.planVolumeTree(at: item.recordNumber)
                totalFiles += plan.totalFiles
                totalBytes += plan.totalBytes
            }
            await engine.begin(plan: TransferPlan(totalFiles: totalFiles, totalBytes: totalBytes, dataClusters: 0))

            try await volume.beginWriteSession()
            defer { Task { try? await volume.endWriteSession() } }

            for item in items {
                try Task.checkCancellation()
                if item.isDirectory {
                    let destDir = try await engine.ensureDirectory(inDirectory: destination, named: item.name)
                    try await Self.copyVolumeTree(
                        engine: engine,
                        volume: volume,
                        from: item.recordNumber,
                        into: destDir,
                        removeSource: isCut
                    )
                    if isCut {
                        try await volume.deleteFile(at: item.recordNumber)
                    }
                } else {
                    try await Self.copyVolumeFile(
                        engine: engine,
                        volume: volume,
                        from: item.recordNumber,
                        into: destination,
                        named: item.name,
                        removeSource: isCut
                    )
                }
            }
            return await engine.currentSummary
        } completion: { [weak self] in
            self?.clipboard = nil
        }
    }

    /// Delete the current selection, recursively.
    public func deleteSelection() {
        guard isWritable, let volume else { return }
        let targets = entries.filter { selection.contains($0.recordNumber) }
        guard !targets.isEmpty else { return }

        run(kind: .delete) { publish in
            let engine = TransferEngine(volume: volume, onProgress: publish)
            var totalFiles = 0
            for t in targets {
                totalFiles += (try await engine.planVolumeTree(at: t.recordNumber)).totalFiles
            }
            await engine.begin(plan: TransferPlan(totalFiles: totalFiles, totalBytes: 0, dataClusters: 0))

            try await volume.beginWriteSession()
            defer { Task { try? await volume.endWriteSession() } }
            for t in targets {
                try Task.checkCancellation()
                try await engine.deleteTree(at: t.recordNumber)
            }
            return await engine.currentSummary
        } completion: { }
    }

    /// Copy files from the host into the current directory (drag-and-drop, or
    /// the Add… button).
    public func importFromHost(paths: [String]) {
        guard isWritable, let volume else { return }
        let destination = currentDirectory

        run(kind: .copy) { publish in
            let engine = TransferEngine(volume: volume, onProgress: publish)
            let clusterBytes = UInt64(volume.bytesPerCluster)
            var totalFiles = 0
            var totalBytes: UInt64 = 0
            var clusters: UInt64 = 0
            for p in paths {
                let plan = try engine.planHostTree(at: p, bytesPerCluster: clusterBytes)
                totalFiles += plan.totalFiles
                totalBytes += plan.totalBytes
                clusters += plan.dataClusters
            }
            // Stop up front rather than failing at 80% with the volume full.
            try await engine.assertFreeSpace(
                for: TransferPlan(totalFiles: totalFiles, totalBytes: totalBytes, dataClusters: clusters)
            )
            await engine.begin(plan: TransferPlan(totalFiles: totalFiles, totalBytes: totalBytes, dataClusters: clusters))

            try await volume.beginWriteSession()
            defer { Task { try? await volume.endWriteSession() } }

            let fm = FileManager.default
            for p in paths {
                try Task.checkCancellation()
                let name = (p as NSString).lastPathComponent
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let dirRN = try await engine.ensureDirectory(inDirectory: destination, named: name)
                    _ = try await engine.copyHostTree(at: p, intoDirectory: dirRN)
                } else {
                    _ = try await engine.copyHostFile(at: p, intoDirectory: destination, named: name)
                }
            }
            return await engine.currentSummary
        } completion: { }
    }

    /// Export the selection to a host directory.
    public func exportSelection(toHostDirectory hostDir: String) {
        guard let volume else { return }
        let targets = entries.filter { selection.contains($0.recordNumber) }
        guard !targets.isEmpty else { return }

        run(kind: .copy) { publish in
            let engine = TransferEngine(volume: volume, onProgress: publish)
            var totalFiles = 0
            var totalBytes: UInt64 = 0
            for t in targets {
                let plan = try await engine.planVolumeTree(at: t.recordNumber)
                totalFiles += plan.totalFiles
                totalBytes += plan.totalBytes
            }
            await engine.begin(plan: TransferPlan(totalFiles: totalFiles, totalBytes: totalBytes, dataClusters: 0))

            let fm = FileManager.default
            for t in targets {
                try Task.checkCancellation()
                let dest = (hostDir as NSString).appendingPathComponent(t.name)
                if t.isDirectory {
                    try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
                    _ = try await engine.pullTree(at: t.recordNumber, toHostDir: dest)
                } else {
                    _ = try await engine.pullFile(at: t.recordNumber, toHostPath: dest, named: t.name)
                }
            }
            return await engine.currentSummary
        } completion: { }
    }

    public func newFolder(named name: String) {
        guard isWritable, let volume else { return }
        let parent = currentDirectory
        Task { [weak self] in
            do {
                try await volume.beginWriteSession()
                _ = try await volume.createFile(named: name, inDirectory: parent, isDirectory: true)
                try await volume.endWriteSession()
                await self?.reload()
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
        }
    }

    /// Cancel the running operation. Files already written stay written — the
    /// sheet reports what actually landed.
    public func cancelOperation() {
        runningTask?.cancel()
    }

    // MARK: - Operation plumbing

    /// Run `body` off the main actor with a progress callback wired to
    /// `operation`, then reload and report. One operation at a time: a second
    /// call while one is running is ignored, so two writers can never race on
    /// the same volume.
    private func run(
        kind: OperationState.Kind,
        _ body: @escaping @Sendable (_ publish: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferSummary,
        completion: @escaping @MainActor () -> Void
    ) {
        guard runningTask == nil else { return }
        errorMessage = nil
        lastResultNote = nil
        operation = OperationState(
            kind: kind,
            filesDone: 0, totalFiles: 0,
            bytesDone: 0, totalBytes: 0,
            currentName: "", fraction: 0,
            detail: "Preparing…"
        )

        // `self` is captured strongly: a `@MainActor` class is implicitly
        // Sendable, and the task always clears `runningTask` on the way out, so
        // the temporary cycle ends when the operation does.
        runningTask = Task {
            let publish: @Sendable (TransferProgress) -> Void = { p in
                Task { @MainActor in
                    guard var op = self.operation else { return }
                    op.filesDone = p.filesDone
                    op.totalFiles = p.totalFiles
                    op.bytesDone = p.bytesDone
                    op.totalBytes = p.totalBytes
                    op.currentName = p.currentName
                    op.fraction = p.fraction
                    op.detail = Self.detailLine(p)
                    self.operation = op
                }
            }

            do {
                let summary = try await body(publish)
                await MainActor.run {
                    self.lastResultNote = Self.note(for: summary, cancelled: false)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.lastResultNote = "Stopped. Items already transferred were kept."
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = Self.message(for: error)
                }
            }

            await MainActor.run {
                self.operation = nil
                self.runningTask = nil
                completion()
            }
            await self.reload()
        }
    }

    /// Copy a volume subtree to another directory on the SAME volume, entry by
    /// entry. Implemented here rather than in the engine because it is a
    /// GUI-only shape: `ntfsctl` moves within a volume with `mv`, which renames
    /// rather than copying.
    private static func copyVolumeTree(
        engine: TransferEngine,
        volume: Volume,
        from source: UInt64,
        into destination: UInt64,
        removeSource: Bool
    ) async throws {
        let children = try await volume.enumerate(directory: source)
        for child in children where child.fileName.namespace != .dos {
            if child.name == "." { continue }
            try Task.checkCancellation()
            if child.isDirectory {
                let sub = try await engine.ensureDirectory(inDirectory: destination, named: child.name)
                try await copyVolumeTree(
                    engine: engine,
                    volume: volume,
                    from: child.recordNumber,
                    into: sub,
                    removeSource: removeSource
                )
                if removeSource {
                    try await volume.deleteFile(at: child.recordNumber)
                }
            } else {
                try await copyVolumeFile(
                    engine: engine,
                    volume: volume,
                    from: child.recordNumber,
                    into: destination,
                    named: child.name,
                    removeSource: removeSource
                )
            }
        }
    }

    /// Copy one file within the volume by streaming it through memory a chunk
    /// at a time — never a whole-file read, so a 4 GB video does not become a
    /// 4 GB allocation.
    private static func copyVolumeFile(
        engine: TransferEngine,
        volume: Volume,
        from source: UInt64,
        into destination: UInt64,
        named name: String,
        removeSource: Bool
    ) async throws {
        // Route through a temporary host file so the streaming, sizing, and
        // index-entry behaviour is exactly the engine's proven path rather than
        // a second implementation.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfs-copy-\(source)-\(UInt64(Date().timeIntervalSince1970 * 1000))")
        defer { try? FileManager.default.removeItem(at: temp) }

        _ = try await engine.pullFile(at: source, toHostPath: temp.path, named: name)
        _ = try await engine.copyHostFile(at: temp.path, intoDirectory: destination, named: name)
        if removeSource {
            try await volume.deleteFile(at: source)
        }
    }

    // MARK: - Presentation helpers

    static func detailLine(_ p: TransferProgress) -> String {
        let done = "\(p.filesDone) of \(p.totalFiles)"
        let bytes = "\(ByteFormat.human(p.bytesDone)) of \(ByteFormat.human(p.totalBytes))"
        guard let eta = p.estimatedSecondsRemaining else {
            return "\(done) — \(bytes)"
        }
        return "\(done) — \(bytes) — about \(timeRemaining(eta)) left"
    }

    /// Coarse ETA wording. Second-level precision on a multi-minute copy reads
    /// as false precision and jitters distractingly.
    static func timeRemaining(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = Double(minutes) / 60
        return String(format: "%.1f hours", hours)
    }

    static func note(for summary: TransferSummary, cancelled: Bool) -> String? {
        var parts: [String] = []
        if summary.skippedFiles > 0 {
            parts.append("\(summary.skippedFiles) item\(summary.skippedFiles == 1 ? "" : "s") skipped")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func message(for error: Error) -> String {
        if let transfer = error as? TransferError, let text = transfer.errorDescription {
            return text
        }
        let text = "\(error)"
        // The raw device node is root:operator 0640 and this app runs
        // unprivileged, so EACCES here is expected and needs an actionable
        // explanation rather than a POSIX code.
        if text.contains("Permission denied") || text.contains("EACCES") || text.contains("errno 13") {
            return "Permission denied opening \(text.contains("/dev/") ? "the device" : "the file") — "
                + "raw disks are owned by root, so this needs administrator access."
        }
        return text
    }
}
