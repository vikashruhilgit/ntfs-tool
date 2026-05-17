import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var diskService: DiskArbitrationService
    @Environment(\.openWindow) private var openWindow
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("NTFS Volumes")
                    .font(.headline)
                Spacer()
                Button(action: { diskService.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            if diskService.volumes.isEmpty {
                Text("No NTFS volumes detected.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(diskService.volumes) { volume in
                    volumeRow(volume)
                }
            }

            if let error = actionError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Divider()

            Button("Extension status: \(installer.shortStatus)") {
                openWindow(id: "settings")
            }
            .buttonStyle(.borderless)

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    @ViewBuilder
    private func volumeRow(_ volume: DiskArbitrationService.Volume) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.displayName)
                    .font(.system(.body, weight: .medium))
                Text("/dev/\(volume.id)" + (volume.mountPoint.map { " · mounted at \($0)" } ?? " · not mounted"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let size = volume.mediaSize {
                    Text(ByteCountFormatter().string(fromByteCount: Int64(size)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if volume.isMounted {
                Button("Eject") {
                    actionError = nil
                    Task {
                        if let err = await diskService.unmount(volume) {
                            actionError = "Eject failed: \(err)"
                        }
                        diskService.refresh()
                    }
                }
            } else {
                Button("Mount") {
                    actionError = nil
                    Task {
                        if let err = await diskService.mount(volume) {
                            actionError = "Mount failed: \(err)"
                        }
                        diskService.refresh()
                    }
                }
            }
        }
    }
}
