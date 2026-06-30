import SwiftUI

/// Outer "bento" card container: raised surface, hairline border, soft elevation.
/// Wraps arbitrary content with consistent padding and corner radius.
public struct SectionCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = Spacing.large, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ntfsCard, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
    }
}

/// Inner metric card: an SF Symbol + label eyebrow over a large value. Used for
/// the Capacity / Used / Free / Cluster bento tiles.
public struct MetricCard: View {
    private let systemImage: String
    private let title: String
    private let value: String
    private let highlighted: Bool

    public init(systemImage: String, title: String, value: String, highlighted: Bool = false) {
        self.systemImage = systemImage
        self.title = title
        self.value = value
        self.highlighted = highlighted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.small / 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.ntfsLabel)
            }
            .foregroundStyle(highlighted ? Color.ntfsPrimary : Color.ntfsOnSurfaceVariant)

            Text(value)
                .font(.ntfsHeadline)
                .foregroundStyle(Color.ntfsOnSurface)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ntfsContainerLow, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
