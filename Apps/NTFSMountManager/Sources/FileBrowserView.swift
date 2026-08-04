import AppKit
import NTFSOps
import NTFSUIKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder-style browser for an NTFS volume, driven entirely by
/// `NTFSUIKit.FileBrowserModel` → `NTFSOps.TransferEngine`.
///
/// This exists because the two normal routes to the files are both shut today:
/// the FSKit mount is blocked pending a provisioned entitlement, and Finder
/// therefore never sees the volume. Reading and writing through NTFSCore
/// directly is what makes copy / paste / move / delete usable in the meantime.
struct FileBrowserView: View {
    @StateObject private var model: FileBrowserModel
    @State private var confirmingDelete = false
    @State private var newFolderName = ""
    @State private var promptingNewFolder = false

    let volumeLabel: String

    init(devicePath: String, volumeLabel: String) {
        _model = StateObject(wrappedValue: FileBrowserModel(devicePath: devicePath))
        self.volumeLabel = volumeLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            locationBar
            Divider()
            if let message = model.errorMessage {
                banner(message, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if !model.isWritable {
                banner(
                    "Read-only — the raw disk is owned by root, so changes need administrator access.",
                    systemImage: "lock.fill",
                    tint: .secondary
                )
            }
            fileList
            Divider()
            statusBar
        }
        .toolbar { toolbarItems }
        .task { await model.open() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.isWritable else { return false }
            loadDroppedPaths(providers)
            return true
        }
        .sheet(isPresented: .constant(model.operation != nil)) {
            if let op = model.operation {
                TransferProgressSheet(operation: op) { model.cancelOperation() }
            }
        }
        .alert("Delete \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")?",
               isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // There is no trash on an NTFS volume we write directly, so the
            // alert has to be honest that this is not recoverable.
            Text("This permanently removes the selected items from \(volumeLabel). It cannot be undone.")
        }
        .alert("New Folder", isPresented: $promptingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.newFolder(named: trimmed) }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    // MARK: - Location bar

    private var locationBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(model.crumbs.count <= 1)
            .help("Go to the enclosing folder")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.crumbs.enumerated()), id: \.element.id) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Button(crumb.name == "/" ? volumeLabel : crumb.name) {
                            Task { await model.navigate(to: crumb) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.crumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var fileList: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { await model.enter(entry) }
                }
            }
            TableColumn("Size") { entry in
                // A folder's own size is meaningless (its $I30 index size, not
                // its contents) — blank is more truthful than a number.
                Text(entry.isDirectory ? "—" : ByteFormat.human(entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Modified") { entry in
                Text(entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(160)
        }
        .contextMenu(forSelectionType: UInt64.self) { _ in
            Button("Copy") { model.copySelection() }
            Button("Cut") { model.cutSelection() }.disabled(!model.isWritable)
            Button("Paste") { model.paste() }.disabled(model.pasteBlockedReason() != nil)
            Divider()
            Button("Save to Mac…") { exportSelection() }
            Divider()
            Button("Delete", role: .destructive) { confirmingDelete = true }
                .disabled(!model.isWritable)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.entries.count) item\(model.entries.count == 1 ? "" : "s")")
            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
            }
            if let clip = model.clipboard {
                Label(
                    "\(clip.entries.count) item\(clip.entries.count == 1 ? "" : "s") ready to \(clip.mode == .cut ? "move" : "copy")",
                    systemImage: clip.mode == .cut ? "scissors" : "doc.on.doc"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let note = model.lastResultNote {
                Text(note).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { promptingNewFolder = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.isWritable)

            Button { importFiles() } label: {
                Label("Add Files", systemImage: "plus")
            }
            .disabled(!model.isWritable)

            Divider()

            Button { model.copySelection() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(model.selection.isEmpty)

            Button { model.cutSelection() } label: {
                Label("Cut", systemImage: "scissors")
            }
            .disabled(model.selection.isEmpty || !model.isWritable)

            Button { model.paste() } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(model.pasteBlockedReason() != nil)
            .help(model.pasteBlockedReason() ?? "Paste into this folder")

            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selection.isEmpty || !model.isWritable)
        }
    }

    // MARK: - Panels

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Volume"
        guard panel.runModal() == .OK else { return }
        model.importFromHost(paths: panel.urls.map(\.path))
    }

    private func exportSelection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        model.exportSelection(toHostDirectory: dir.path)
    }

    private func loadDroppedPaths(_ providers: [NSItemProvider]) {
        // Item providers resolve asynchronously; collect them all before
        // starting one operation, so a 10-file drop is one progress bar rather
        // than ten competing ones (the model runs a single operation at a time
        // and would drop the rest).
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [String] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    paths.append(url.path)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !paths.isEmpty else { return }
            model.importFromHost(paths: paths)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).font(.callout)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// Modal progress for a running copy / move / delete, with a working Cancel.
///
/// Cancel is real: the engine checks for cancellation between 1 MiB chunks, so
/// a multi-gigabyte copy stops promptly instead of running to completion.
struct TransferProgressSheet: View {
    let operation: OperationState
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(operation.kind.rawValue) \(operation.currentName.isEmpty ? "…" : operation.currentName)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            // A delete has no byte total, so an indeterminate bar is honest
            // where a 0%-forever determinate bar is not.
            if operation.totalBytes > 0 {
                ProgressView(value: operation.fraction)
            } else {
                ProgressView()
            }

            Text(operation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack {
                Spacer()
                Button("Stop", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
