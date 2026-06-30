import SwiftUI
import NTFSUIKit

/// Restyled menu-bar quick panel. Uses the NTFSUIKit design system: token/material
/// background, per-volume rows with free-space placeholder + RW/RO badge +
/// extension-status dot, a designed empty state, and a button opening the main
/// window. DiskArbitration / ExtensionInstaller wiring is unchanged.
struct MenuBarContent: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var diskService: DiskArbitrationService
    @Environment(\.openWindow) private var openWindow
    @State private var actionError: String?
    @State private var busyVolumeID: String?

    private var extensionActive: Bool { installer.shortStatus == "activated" }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            header

            Divider().overlay(Color.ntfsOutline.opacity(0.3))

            if diskService.volumes.isEmpty {
                EmptyStateView(
                    systemImage: "externaldrive.badge.questionmark",
                    title: "No NTFS volumes connected",
                    message: "Connect an NTFS drive and it will appear here."
                )
            } else {
                VStack(spacing: Spacing.unit) {
                    ForEach(diskService.volumes) { volume in
                        row(volume)
                    }
                }
            }

            if let error = actionError {
                Text(error)
                    .font(.ntfsBody)
                    .foregroundStyle(Color.ntfsError)
                    .lineLimit(3)
                    .transition(.opacity)
            }

            Divider().overlay(Color.ntfsOutline.opacity(0.3))

            HStack {
                StatusBadge(
                    "Extension: \(installer.shortStatus)",
                    tone: extensionActive ? .success : .neutral
                )
                Spacer()
                Button {
                    diskService.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh volumes")
                .accessibilityLabel("Refresh volume list")
            }

            Button {
                openWindow(id: "main")
            } label: {
                Label("Open NTFS Manager", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle())
            .accessibilityLabel("Open the NTFS Manager window")

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .foregroundStyle(Color.ntfsOnSurfaceVariant)
        }
        .padding(Spacing.medium)
        .frame(width: 340)
        .background(Color.ntfsSurface)
        .animation(.easeInOut(duration: 0.2), value: actionError)
    }

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(Color.ntfsPrimary)
            Text("NTFS Volumes")
                .font(.ntfsTitle)
                .foregroundStyle(Color.ntfsOnSurface)
            Spacer()
        }
    }

    @ViewBuilder
    private func row(_ volume: DiskArbitrationService.Volume) -> some View {
        VolumeRow(model: volume.rowModel(extensionActive: extensionActive)) {
            if busyVolumeID == volume.id {
                ProgressView().scaleEffect(0.6)
            } else if volume.isMounted {
                Button("Eject") { perform(volume, mount: false) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Eject \(volume.displayName)")
            } else {
                Button("Mount") { perform(volume, mount: true) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Mount \(volume.displayName)")
            }
        }
    }

    private func perform(_ volume: DiskArbitrationService.Volume, mount: Bool) {
        actionError = nil
        busyVolumeID = volume.id
        Task {
            let err = mount ? await diskService.mount(volume) : await diskService.unmount(volume)
            if let err {
                actionError = "\(mount ? "Mount" : "Eject") failed: \(err)"
            }
            busyVolumeID = nil
            diskService.refresh()
        }
    }
}
