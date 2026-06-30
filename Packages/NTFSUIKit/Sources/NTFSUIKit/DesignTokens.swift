import SwiftUI

// MARK: - Color tokens
//
// Every color used by the GUI is sourced from the NTFSColors.xcassets catalog
// bundled with this package. Views must reference these named tokens — never an
// inline `Color(red:…)` / hex literal — so that Light/Dark variants stay correct
// and the palette has a single source of truth.

public extension Color {
    /// Loads a named color from this package's asset catalog.
    private static func ntfs(_ name: String) -> Color {
        Color(name, bundle: .module)
    }

    /// App page background (`#131313` dark / derived light).
    static let ntfsSurface = ntfs("page-surface")
    /// Raised card / panel background (`#1F1F1F`).
    static let ntfsCard = ntfs("raised-card")
    /// Low-emphasis container fill (`#1c1b1b`).
    static let ntfsContainerLow = ntfs("surface-container-low")
    /// Mid container fill (`#201f1f`).
    static let ntfsContainer = ntfs("surface-container")
    /// Bright hover container fill (`#393939`).
    static let ntfsContainerBright = ntfs("surface-bright")

    /// Primary readable foreground (`#e5e2e1`).
    static let ntfsOnSurface = ntfs("on-surface")
    /// Secondary / muted foreground (`#c0c6d6`).
    static let ntfsOnSurfaceVariant = ntfs("on-surface-variant")

    /// Material-3 primary accent (`#aac7ff`).
    static let ntfsPrimary = ntfs("primary")
    /// macOS system blue used for the call-to-action buttons (`#0A84FF`).
    static let ntfsAccent = ntfs("accent")

    /// Error foreground (`#ffb4ab`).
    static let ntfsError = ntfs("error")
    /// Error container fill (`#93000a`).
    static let ntfsErrorContainer = ntfs("error-container")
    /// Success / clean state (emerald).
    static let ntfsSuccess = ntfs("success")
    /// Hairline outline / divider (`#8b91a0`).
    static let ntfsOutline = ntfs("outline")
}

// MARK: - Type scale
//
// SF Pro (default design) for text, SF Mono for code/paths. Mirrors the mock's
// scale but uses relative point sizes so Dynamic Type still scales the text.

public extension Font {
    /// Display 32 / weight 600 — big numeric / volume titles.
    static let ntfsDisplay = Font.system(size: 32, weight: .semibold, design: .default)
    /// Headline 20 / weight 600 — metric values, section heroes.
    static let ntfsHeadline = Font.system(size: 20, weight: .semibold, design: .default)
    /// Title 16 / weight 500 — card titles, primary row text.
    static let ntfsTitle = Font.system(size: 16, weight: .medium, design: .default)
    /// Body 14 / weight 400 — default body copy.
    static let ntfsBody = Font.system(size: 14, weight: .regular, design: .default)
    /// Label 11 / weight 600 — uppercase eyebrow labels.
    static let ntfsLabel = Font.system(size: 11, weight: .semibold, design: .default)

    /// Monospaced code / device paths (SF Mono), 13 / weight 450.
    static let ntfsCode = Font.system(size: 13, weight: .regular, design: .monospaced)
    /// Smaller monospaced caption for metadata rows.
    static let ntfsCodeCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Spacing & radius

public enum Spacing {
    /// 4pt base unit.
    public static let unit: CGFloat = 4
    /// 8pt — tight stacks, control padding.
    public static let small: CGFloat = 8
    /// 16pt — default gutter / card padding.
    public static let medium: CGFloat = 16
    /// 24pt — container padding.
    public static let large: CGFloat = 24
    /// 32pt — major section gaps.
    public static let xlarge: CGFloat = 32
}

public enum Radius {
    /// 8pt — small chips / inner fills.
    public static let small: CGFloat = 8
    /// 12pt — controls / buttons.
    public static let control: CGFloat = 12
    /// 16pt — inner cards.
    public static let card: CGFloat = 16
    /// 24pt — outer bento cards.
    public static let large: CGFloat = 24
    /// Fully-rounded pill.
    public static let pill: CGFloat = 999
}
