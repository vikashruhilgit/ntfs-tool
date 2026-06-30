import AppKit
import SwiftUI
import NTFSUIKit

/// The bento dashboard for a single selected volume: identity header, the native
/// storage ring + Capacity/Used/Free/Cluster metric cards, a Volume Info section,
/// a Verify action, and a read-only Drive Health panel. All NTFS facts come from
/// NTFSCore via `VolumeDetailLoader` — the GUI never execs `ntfsctl`.
struct VolumeDashboardView: View {
    let volume: DiskArbitrationService.Volume
    let extensionActive: Bool
    @ObservedObject var diskService: DiskArbitrationService

    @StateObject private var loader: VolumeDetailLoader
    @State private var actionError: String?
    @State private var busy = false

    // Danger Zone state.
    @State private var showFormatConfirm = false
    @State private var showRepairConfirm = false
    @State private var formatLabel: String

    init(volume: DiskArbitrationService.Volume, extensionActive: Bool, diskService: DiskArbitrationService) {
        self.volume = volume
        self.extensionActive = extensionActive
        self.diskService = diskService
        // A single loader backs both the read-only dashboard and the writable
        // Danger Zone actions: it opens the device writable only inside
        // runFormat/runRepair, read-only everywhere else.
        _loader = StateObject(wrappedValue: VolumeDetailLoader(
            devicePath: volume.devicePath,
            label: volume.displayName,
            isWritable: true
        ))
        _formatLabel = State(initialValue: volume.displayName)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header
                if let actionError {
                    messageRow(actionError, tone: .error, icon: "exclamationmark.triangle")
                        .padding(Spacing.small)
                        .background(Color.ntfsError.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .transition(.opacity)
                }
                bento
                infoAndHealth
                dangerZone
            }
            .padding(Spacing.large)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.ntfsSurface)
        .task(id: volume.id) { await loader.load() }
        .animation(.easeInOut(duration: 0.25), value: loader.info)
        .animation(.easeInOut(duration: 0.25), value: loader.verify)
        .animation(.easeInOut(duration: 0.25), value: loader.format)
        .animation(.easeInOut(duration: 0.25), value: loader.repair)
        .animation(.easeInOut(duration: 0.2), value: actionError)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.ntfsContainer)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: volume.isMounted ? "externaldrive.fill" : "externaldrive")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.ntfsPrimary)
                )

            VStack(alignment: .leading, spacing: Spacing.unit) {
                HStack(spacing: Spacing.small) {
                    Text(volume.displayName)
                        .font(.ntfsDisplay)
                        .foregroundStyle(Color.ntfsOnSurface)
                    StatusBadge(
                        volume.isMounted ? "Mounted" : "Unmounted",
                        tone: volume.isMounted ? .success : .neutral
                    )
                }
                Text("NTFS · \(volume.mountPoint ?? "not mounted") · \(volume.devicePath)")
                    .font(.ntfsCode)
                    .foregroundStyle(Color.ntfsOnSurfaceVariant)
            }

            Spacer()
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.small) {
            if volume.isMounted, let mountPoint = volume.mountPoint {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint)])
                } label: {
                    Label("Reveal", systemImage: "magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Reveal \(volume.displayName) in Finder")
            }

            Button {
                Task { await loader.runVerify() }
            } label: {
                Label("Verify", systemImage: "checkmark.seal")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(loader.verify.isLoading)
            .accessibilityLabel("Verify volume \(volume.displayName)")

            if volume.isMounted {
                Button { perform(mount: false) } label: {
                    Label("Eject", systemImage: "eject")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(busy)
                .accessibilityLabel("Eject \(volume.displayName)")
            } else {
                Button { perform(mount: true) } label: {
                    Label("Mount", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(busy)
                .accessibilityLabel("Mount \(volume.displayName)")
            }
            if busy { ProgressView().scaleEffect(0.6) }
        }
    }

    // MARK: - Bento (ring + metric cards)

    private var bento: some View {
        SectionCard {
            HStack(alignment: .center, spacing: Spacing.xlarge) {
                ringView
                metricGrid
            }
        }
    }

    @ViewBuilder
    private var ringView: some View {
        switch loader.info {
        case .loading, .idle:
            ProgressView()
                .frame(width: 168, height: 168)
        case let .loaded(vm):
            StorageRing(fraction: vm.percentUsed, percentLabel: vm.percentUsedDisplay)
        case .failed:
            StorageRing(fraction: 0, percentLabel: "—")
        }
    }

    private var metricGrid: some View {
        let vm = loader.info.value
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.medium) {
            MetricCard(systemImage: "internaldrive", title: "Capacity", value: vm?.totalDisplay ?? "—")
            MetricCard(systemImage: "chart.pie", title: "Used", value: vm?.usedDisplay ?? "—", highlighted: true)
            MetricCard(systemImage: "checkmark.circle", title: "Free Space", value: vm?.freeDisplay ?? "—")
            MetricCard(systemImage: "square.grid.3x3", title: "Cluster Size", value: vm?.clusterDisplay ?? "—")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Volume Info + Drive Health

    private var infoAndHealth: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            volumeInfoCard
            driveHealthCard
        }
    }

    private var volumeInfoCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                Text("Volume Info")
                    .font(.ntfsTitle)
                    .foregroundStyle(Color.ntfsOnSurface)

                switch loader.info {
                case .idle, .loading:
                    HStack { ProgressView().scaleEffect(0.7); Text("Reading volume…").font(.ntfsBody).foregroundStyle(Color.ntfsOnSurfaceVariant) }
                case let .failed(message):
                    messageRow(message, tone: .error, icon: "exclamationmark.triangle")
                case let .loaded(vm):
                    VStack(spacing: 0) {
                        infoRow("Label", vm.label)
                        infoRow("Total Size", vm.totalDisplay)
                        infoRow("Free Space", vm.freeDisplay)
                        infoRow("Bytes / Cluster", "\(vm.clusterDisplay)")
                        infoRow("MFT Location", vm.mftLocationDisplay, mono: true)
                        infoRow("Version", vm.versionDisplay, last: true)
                    }
                }
            }
        }
    }

    private var driveHealthCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                HStack {
                    Text("Drive Health")
                        .font(.ntfsTitle)
                        .foregroundStyle(Color.ntfsOnSurface)
                    Spacer()
                    if let vm = loader.info.value {
                        Image(systemName: vm.isDirty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(vm.isDirty ? Color.ntfsError : Color.ntfsSuccess)
                    }
                }

                switch loader.info {
                case .idle, .loading:
                    HStack { ProgressView().scaleEffect(0.7); Text("Checking…").font(.ntfsBody).foregroundStyle(Color.ntfsOnSurfaceVariant) }
                case let .failed(message):
                    messageRow(message, tone: .error, icon: "exclamationmark.triangle")
                case let .loaded(vm):
                    VStack(spacing: 0) {
                        healthRow("Overall Status", value: vm.healthStatus, tone: vm.isDirty ? .error : .success)
                        infoRow("Permissions", vm.permissionDisplay, mono: true)
                        infoRow("Last Checked", lastCheckedText, last: true)
                    }
                }

                // Verify result surfaces below the health summary.
                verifyResultView
            }
        }
    }

    @ViewBuilder
    private var verifyResultView: some View {
        switch loader.verify {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: Spacing.small) {
                ProgressView().scaleEffect(0.6)
                Text("Verifying…").font(.ntfsBody).foregroundStyle(Color.ntfsOnSurfaceVariant)
            }
            .transition(.opacity)
        case let .failed(message):
            messageRow(message, tone: .error, icon: "exclamationmark.triangle")
                .transition(.opacity)
        case let .loaded(result):
            VStack(alignment: .leading, spacing: Spacing.unit) {
                HStack(spacing: Spacing.small) {
                    Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.isClean ? Color.ntfsSuccess : Color.ntfsError)
                    Text(result.isClean ? "Verify: clean" : "Verify: problems found")
                        .font(.ntfsBody)
                        .foregroundStyle(Color.ntfsOnSurface)
                }
                if !result.problems.isEmpty {
                    Text(result.summary)
                        .font(.ntfsCodeCaption)
                        .foregroundStyle(Color.ntfsOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (result.isClean ? Color.ntfsSuccess : Color.ntfsError).opacity(0.1),
                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            )
            .transition(.opacity)
        }
    }

    private var lastCheckedText: String {
        if let result = loader.verify.value {
            return result.checkedAt.formatted(date: .omitted, time: .shortened)
        }
        return "Not yet verified"
    }

    // MARK: - Small row helpers

    private func infoRow(_ key: String, _ value: String, mono: Bool = false, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(key).font(.ntfsBody).foregroundStyle(Color.ntfsOnSurfaceVariant)
                Spacer()
                Text(value)
                    .font(mono ? .ntfsCodeCaption : .ntfsBody)
                    .foregroundStyle(Color.ntfsOnSurface)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, Spacing.small)
            if !last { Divider().overlay(Color.ntfsOutline.opacity(0.15)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(value)")
    }

    private func healthRow(_ key: String, value: String, tone: StatusTone) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(key).font(.ntfsBody).foregroundStyle(Color.ntfsOnSurfaceVariant)
                Spacer()
                Text(value).font(.ntfsBody.weight(.semibold)).foregroundStyle(tone.foreground)
            }
            .padding(.vertical, Spacing.small)
            Divider().overlay(Color.ntfsOutline.opacity(0.15))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(value)")
    }

    private func messageRow(_ message: String, tone: StatusTone, icon: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: icon).foregroundStyle(tone.foreground)
            Text(message)
                .font(.ntfsBody)
                .foregroundStyle(Color.ntfsOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    // MARK: - Danger Zone (destructive actions)

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(alignment: .top, spacing: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.unit) {
                    Label("Destructive Actions", systemImage: "exclamationmark.triangle.fill")
                        .font(.ntfsTitle)
                        .foregroundStyle(Color.ntfsError)
                    Text("These operations will erase or rewrite the volume data permanently.")
                        .font(.ntfsBody)
                        .foregroundStyle(Color.ntfsOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: Spacing.small) {
                    Button { showRepairConfirm = true } label: {
                        Label("Repair…", systemImage: "bandage")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(loader.repair.isLoading || loader.format.isLoading)
                    .accessibilityLabel("Repair volume \(volume.displayName)")

                    Button { showFormatConfirm = true } label: {
                        Label("Format as NTFS…", systemImage: "trash")
                    }
                    .buttonStyle(DangerButtonStyle())
                    .disabled(loader.format.isLoading || loader.repair.isLoading)
                    .accessibilityLabel("Format \(volume.displayName) as NTFS, erasing all data")
                }
            }

            if volume.isMounted {
                Text("Tip: eject this volume first — Format and Repair require the device to be unmounted.")
                    .font(.ntfsCodeCaption)
                    .foregroundStyle(Color.ntfsOnSurfaceVariant)
            }

            dangerOutcomeView
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ntfsErrorContainer.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .stroke(Color.ntfsError.opacity(0.30), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // Hairline accent bar marking the zone as destructive.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.ntfsError.opacity(0.5))
                .frame(width: 3)
                .padding(.vertical, Spacing.medium)
        }
        .confirmationDialog(
            "Erase \(volume.displayName) (\(volume.devicePath))?",
            isPresented: $showFormatConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase and Format as NTFS", role: .destructive) {
                let label = formatLabel
                perform { await loader.runFormat(label: label) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently destroys all data on \(volume.devicePath). The volume will be reformatted as a fresh NTFS filesystem.")
        }
        .confirmationDialog(
            "Repair \(volume.displayName) (\(volume.devicePath))?",
            isPresented: $showRepairConfirm,
            titleVisibility: .visible
        ) {
            Button("Run Consistency Check") {
                perform { await loader.runRepair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs a read-only consistency audit on \(volume.devicePath). If the volume is only flagged dirty, the dirty flag is cleared. Real corruption is reported but must be repaired with Windows chkdsk /F.")
        }
    }

    @ViewBuilder
    private var dangerOutcomeView: some View {
        switch loader.format {
        case .loading:
            outcomeRow(spinner: true, text: "Formatting \(volume.devicePath)…", tone: .neutral)
        case let .failed(message):
            outcomeRow(text: "Format failed: \(message)", tone: .error, icon: "exclamationmark.triangle.fill")
        case let .loaded(result):
            outcomeRow(text: result.summary, tone: .success, icon: "checkmark.circle.fill")
        case .idle:
            EmptyView()
        }

        switch loader.repair {
        case .loading:
            outcomeRow(spinner: true, text: "Running consistency audit…", tone: .neutral)
        case let .failed(message):
            outcomeRow(text: "Repair failed: \(message)", tone: .error, icon: "exclamationmark.triangle.fill")
        case let .loaded(result):
            outcomeRow(
                text: result.summary,
                tone: result.isResolved ? .success : .error,
                icon: result.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        case .idle:
            EmptyView()
        }
    }

    private func outcomeRow(spinner: Bool = false, text: String, tone: StatusTone, icon: String? = nil) -> some View {
        HStack(alignment: .top, spacing: Spacing.small) {
            if spinner {
                ProgressView().scaleEffect(0.6)
            } else if let icon {
                Image(systemName: icon).foregroundStyle(tone.foreground)
            }
            Text(text)
                .font(.ntfsBody)
                .foregroundStyle(Color.ntfsOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.foreground.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Mount/eject

    /// Generic async action runner mirroring `perform(mount:)`: clears prior
    /// error, flips `busy`, runs the work, refreshes DiskArbitration.
    private func perform(_ work: @escaping () async -> Void) {
        actionError = nil
        busy = true
        Task {
            await work()
            busy = false
            diskService.refresh()
        }
    }

    private func perform(mount: Bool) {
        actionError = nil
        busy = true
        Task {
            let err = mount ? await diskService.mount(volume) : await diskService.unmount(volume)
            if let err {
                actionError = "\(mount ? "Mount" : "Eject") failed: \(err)"
            }
            busy = false
            diskService.refresh()
        }
    }
}
