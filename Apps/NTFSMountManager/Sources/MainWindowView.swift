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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            detail
        }
        .background(Color.ntfsSurface)
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
        // A List with .sidebar style is what gives the native title-bar inset
        // (content sits below the close/min/max controls) and an edge-to-edge
        // background — a custom VStack sidebar gets neither, which is what
        // caused the traffic-light overlap and the doubled left border.
        List {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    sidebarButton(item)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.ntfsPrimary)
                    Text("NTFS Utility")
                        .font(.ntfsTitle)
                        .foregroundStyle(Color.ntfsOnSurface)
                }
                .textCase(nil)
                .padding(.vertical, Spacing.unit)
            }

            if section != .settings {
                Section {
                    if filteredVolumes.isEmpty {
                        Text("No volumes")
                            .font(.ntfsBody)
                            .foregroundStyle(Color.ntfsOnSurfaceVariant)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    } else {
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
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.ntfsContainerLow)
        .safeAreaInset(edge: .bottom) {
            StatusBadge(
                "Extension: \(installer.shortStatus)",
                tone: extensionActive ? .success : .neutral
            )
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ntfsContainerLow)
        }
    }

    private func sidebarButton(_ item: SidebarItem) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: Spacing.small) {
                Image(systemName: item.systemImage)
                Text(item.rawValue).font(.ntfsTitle)
                Spacer()
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.small)
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
