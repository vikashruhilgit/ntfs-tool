import SwiftUI

/// Display model for a volume row, decoupled from DiskArbitration so the row is
/// reusable and testable. `freeFraction` (if known) drives the free-space bar.
public struct VolumeRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let isMounted: Bool
    public let isWritable: Bool
    public let extensionActive: Bool
    /// 0...1 fraction of capacity that is FREE, or nil if not yet read.
    public let freeFraction: Double?
    public let capacityDisplay: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        isMounted: Bool,
        isWritable: Bool,
        extensionActive: Bool,
        freeFraction: Double? = nil,
        capacityDisplay: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isMounted = isMounted
        self.isWritable = isWritable
        self.extensionActive = extensionActive
        self.freeFraction = freeFraction
        self.capacityDisplay = capacityDisplay
    }
}

/// A free-space bar: filled portion = used, track = total.
public struct FreeSpaceBar: View {
    private let freeFraction: Double   // 0...1 free

    public init(freeFraction: Double) {
        self.freeFraction = min(max(freeFraction, 0), 1)
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.ntfsOutline.opacity(0.25))
                Capsule()
                    .fill(Color.ntfsAccent)
                    .frame(width: geo.size.width * (1 - freeFraction))
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Free space")
        .accessibilityValue("\(Int((freeFraction * 100).rounded())) percent free")
    }
}

/// Reusable volume row used in the menu-bar panel and sidebar lists. Shows the
/// volume identity, an optional free-space bar, a read/read-write badge, and an
/// extension-status dot. Action buttons are supplied by the host via `trailing`.
public struct VolumeRow<Trailing: View>: View {
    private let model: VolumeRowModel
    private let trailing: Trailing
    private let isSelected: Bool

    public init(
        model: VolumeRowModel,
        isSelected: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.model = model
        self.isSelected = isSelected
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.small) {
            StatusDot(
                tone: model.extensionActive ? .success : .neutral,
                pulsing: model.extensionActive,
                label: model.extensionActive ? "Extension active" : "Extension inactive"
            )

            VStack(alignment: .leading, spacing: Spacing.unit) {
                HStack(spacing: Spacing.small) {
                    Text(model.title)
                        .font(.ntfsTitle)
                        .foregroundStyle(Color.ntfsOnSurface)
                        .lineLimit(1)
                    StatusBadge(
                        model.isWritable ? "RW" : "RO",
                        tone: model.isWritable ? .primary : .neutral,
                        showDot: false
                    )
                }
                Text(model.subtitle)
                    .font(.ntfsCodeCaption)
                    .foregroundStyle(Color.ntfsOnSurfaceVariant)
                    .lineLimit(1)
                if let free = model.freeFraction {
                    FreeSpaceBar(freeFraction: free)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: Spacing.small)
            trailing
        }
        .padding(Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isSelected ? Color.ntfsPrimary.opacity(0.15) : Color.clear)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.title), \(model.isMounted ? "mounted" : "not mounted"), \(model.isWritable ? "read write" : "read only")")
    }
}

public extension VolumeRow where Trailing == EmptyView {
    init(model: VolumeRowModel, isSelected: Bool = false) {
        self.init(model: model, isSelected: isSelected) { EmptyView() }
    }
}
