import SwiftUI

/// Native SwiftUI storage ring (NOT a shader). Renders percent-used as a trimmed
/// circle with the percentage and an "USED" caption in the center, matching the
/// mock's ring. Driven by real `$Bitmap` free-space data (a `0...1` fraction).
public struct StorageRing: View {
    private let fraction: Double          // 0...1
    private let percentLabel: String
    private let diameter: CGFloat
    private let lineWidth: CGFloat

    public init(fraction: Double, percentLabel: String, diameter: CGFloat = 168, lineWidth: CGFloat = 14) {
        self.fraction = min(max(fraction, 0), 1)
        self.percentLabel = percentLabel
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ntfsOutline.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    Color.ntfsAccent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: fraction)
            VStack(spacing: 2) {
                Text(percentLabel)
                    .font(.ntfsHeadline)
                    .foregroundStyle(Color.ntfsOnSurface)
                Text("USED")
                    .font(.ntfsLabel)
                    .tracking(0.6)
                    .foregroundStyle(Color.ntfsOnSurfaceVariant)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage used")
        .accessibilityValue("\(percentLabel) used")
    }
}
