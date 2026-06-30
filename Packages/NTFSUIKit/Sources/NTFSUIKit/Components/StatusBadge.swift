import SwiftUI

/// Semantic colors a status badge / pill can take, mapped to design tokens.
public enum StatusTone: Sendable {
    case success
    case primary
    case error
    case neutral

    public var foreground: Color {
        switch self {
        case .success: return .ntfsSuccess
        case .primary: return .ntfsPrimary
        case .error:   return .ntfsError
        case .neutral: return .ntfsOnSurfaceVariant
        }
    }
}

/// A small filled pill with an optional leading dot, e.g. "Mounted" / "Clean".
public struct StatusBadge: View {
    private let text: String
    private let tone: StatusTone
    private let showDot: Bool

    public init(_ text: String, tone: StatusTone = .neutral, showDot: Bool = true) {
        self.text = text
        self.tone = tone
        self.showDot = showDot
    }

    public var body: some View {
        HStack(spacing: Spacing.small / 2) {
            if showDot {
                Circle()
                    .fill(tone.foreground)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.ntfsLabel)
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.unit)
        .foregroundStyle(tone.foreground)
        .background(tone.foreground.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(tone.foreground.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A standalone status dot (e.g. extension-active indicator on a row).
public struct StatusDot: View {
    private let tone: StatusTone
    private let pulsing: Bool
    private let label: String

    public init(tone: StatusTone, pulsing: Bool = false, label: String) {
        self.tone = tone
        self.pulsing = pulsing
        self.label = label
    }

    @State private var animate = false

    public var body: some View {
        Circle()
            .fill(tone.foreground)
            .frame(width: 8, height: 8)
            .opacity(pulsing && animate ? 0.4 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: animate)
            .onAppear { if pulsing { animate = true } }
            .accessibilityLabel(label)
    }
}
