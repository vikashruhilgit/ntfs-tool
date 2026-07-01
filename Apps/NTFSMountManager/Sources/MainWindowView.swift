import SwiftUI
import NTFSUIKit

/// Sidebar sections for the main window.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case all = "All Volumes"
    case mounted = "Mounted"
    case unmounted = "Unmounted"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all:       return "externaldrive"
        case .mounted:   return "checkmark.circle"
        case .unmounted: return "minus.circle"
        case .settings:  return "gearshape"
        }
    }
}

/// Top-level main window: a left sidebar (All / Mounted / Unmounted / Settings)
/// and a detail pane that shows the bento dashboard for the selected volume.
struct MainWindowView: View {
    @ObservedObject var installer: ExtensionInstaller
    @ObservedObject var diskService: DiskArbitrationService

    @State private var section: SidebarItem = .all
    @State private var selectedVolumeID: String?

    /// First-run onboarding gate — shows the read-write flow sheet once.
    @AppStorage("hasSeenReadWriteOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    private var extensionActive: Bool { installer.shortStatus == "activated" }

    private var filteredVolumes: [DiskArbitrationService.Volume] {
        switch section {
        case .all, .settings: return diskService.volumes
        case .mounted:        return diskService.volumes.filter(\.isMounted)
        case .unmounted:      return diskService.volumes.filter { !$0.isMounted }
        }
    }

    private var selectedVolume: DiskArbitrationService.Volume? {
        diskService.volumes.first { $0.id == selectedVolumeID }
    }

    var body: some View {
        // Custom HStack split instead of NavigationSplitView: on macOS 26 the
        // split view fails to recompute the sidebar's title-bar inset on
        // zoom/maximize/restore, sliding the top rows under the traffic lights.
        // A plain HStack lays out with the standard window safe area, which is
        // stable at every size. The sidebar owns its own title-bar clearance.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 264)
            Divider()
                .overlay(Color.ntfsOutline.opacity(0.3))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ntfsSurface.ignoresSafeArea())
        .onAppear {
            diskService.refresh()
            if !hasSeenOnboarding { showOnboarding = true }
        }
        .onChange(of: filteredVolumes.map(\.id)) { _, ids in
            if selectedVolumeID == nil || !(ids.contains(selectedVolumeID ?? "")) {
                selectedVolumeID = ids.first
            }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
            FirstRunSheet(isPresented: $showOnboarding)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.small) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(Color.ntfsPrimary)
                Text("NTFS Utility")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ntfsOnSurface)
            }
            .padding(.horizontal, Spacing.small)

            VStack(alignment: .leading, spacing: Spacing.unit) {
                ForEach(SidebarItem.allCases) { item in
                    sidebarButton(item)
                }
            }

            Divider().overlay(Color.ntfsOutline.opacity(0.25))

            if section != .settings {
                if filteredVolumes.isEmpty {
                    Text("No volumes")
                        .font(.ntfsBody)
                        .foregroundStyle(Color.ntfsOnSurfaceVariant)
                        .padding(.horizontal, Spacing.small)
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.unit) {
                            ForEach(filteredVolumes) { volume in
                                Button {
                                    selectedVolumeID = volume.id
                                } label: {
                                    VolumeRow(
                                        model: volume.rowModel(extensionActive: extensionActive),
                                        isSelected: volume.id == selectedVolumeID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            StatusBadge(
                "Extension: \(installer.shortStatus)",
                tone: extensionActive ? .success : .neutral
            )
            .padding(.horizontal, Spacing.small)
        }
        // The window's safe area already sits below the title bar; this pads a
        // little further so the header clears the traffic lights with breathing
        // room. Fixed inset ⇒ stable at every window size (incl. zoom).
        .padding(.top, Spacing.large)
        .padding(.horizontal, Spacing.small)
        .padding(.bottom, Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Background bleeds to the window edges (under the traffic lights);
        // the content above stays within the safe area.
        .background(Color.ntfsContainerLow.ignoresSafeArea())
    }

    private func sidebarButton(_ item: SidebarItem) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: Spacing.small) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18, alignment: .center)
                Text(item.rawValue)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 6)
            .foregroundStyle(section == item ? Color.ntfsPrimary : Color.ntfsOnSurfaceVariant)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(section == item ? Color.ntfsPrimary.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(section == item ? [.isSelected] : [])
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if section == .settings {
            SettingsDetailView(installer: installer)
        } else if let volume = selectedVolume {
            VolumeDashboardView(
                volume: volume,
                extensionActive: extensionActive,
                diskService: diskService
            )
            .id(volume.id) // fresh loader per volume
        } else {
            EmptyStateView(
                title: "No NTFS volumes connected",
                message: "Connect an NTFS drive to inspect its capacity, health, and volume info."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.ntfsSurface)
        }
    }
}

/// Settings detail re-uses the extension activation controls in the design shell.
struct SettingsDetailView: View {
    @ObservedObject var installer: ExtensionInstaller

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("Settings")
                    .font(.ntfsDisplay)
                    .foregroundStyle(Color.ntfsOnSurface)

                SectionCard {
                    VStack(alignment: .leading, spacing: Spacing.medium) {
                        Text("System Extension")
                            .font(.ntfsTitle)
                            .foregroundStyle(Color.ntfsOnSurface)
                        Text(installer.status)
                            .font(.ntfsCode)
                            .foregroundStyle(Color.ntfsOnSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Spacing.small) {
                            Button("Activate Extension") { installer.activate() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(installer.isWorking)
                            Button("Deactivate") { installer.deactivate() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(installer.isWorking)
                            if installer.isWorking { ProgressView().scaleEffect(0.6) }
                        }
                    }
                }
            }
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.ntfsSurface)
    }
}
