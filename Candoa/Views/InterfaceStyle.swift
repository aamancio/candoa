import AppKit
import SwiftUI

enum AppColor {
    enum Apple {
        /// Reference value for persisting an explicitly selected blue Space.
        /// The app interface uses the person's dynamic macOS accent instead.
        static let systemBlueReferenceHex = "#007AFF"
        static var systemBlue: Color { Color(nsColor: .systemBlue) }
        static var systemRed: Color { Color(nsColor: .systemRed) }
        static var systemOrange: Color { Color(nsColor: .systemOrange) }
        static var systemYellow: Color { Color(nsColor: .systemYellow) }
        static var systemGreen: Color { Color(nsColor: .systemGreen) }
        static var systemMint: Color { Color(nsColor: .systemMint) }
        static var systemTeal: Color { Color(nsColor: .systemTeal) }
        static var systemCyan: Color { Color(nsColor: .systemCyan) }
        static var systemIndigo: Color { Color(nsColor: .systemIndigo) }
        static var systemPurple: Color { Color(nsColor: .systemPurple) }
        static var systemPink: Color { Color(nsColor: .systemPink) }
        static var systemBrown: Color { Color(nsColor: .systemBrown) }
        static var systemGray: Color { Color(nsColor: .systemGray) }
        static var controlAccent: Color { Color(nsColor: .controlAccentColor) }
    }

    static let blueThemeHex = Apple.systemBlueReferenceHex
    static var accent: Color { Apple.controlAccent }
    static var focusRing: Color { accent.opacity(0.58) }
    static var selectedFill: Color { accent.opacity(0.16) }
    static var success: Color { Apple.systemGreen }
    static var warning: Color { Apple.systemOrange }
    static var danger: Color { Apple.systemRed }
}

/// Space themes personalize identity and passive atmosphere. Interactive
/// controls continue to use `AppColor.accent` and semantic system colors.
enum ThemeStyle {
    static func identityColor(for hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return AppColor.Apple.systemGray }
        return Color(spaceHex: hex)
    }
}

enum InterfaceStyle {
    static let sidebarWidth: CGFloat = 234
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let workspaceBackground = Color(nsColor: .underPageBackgroundColor)
    static var neutralWindowBackdrop: some View {
        workspaceBackground
    }
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    /// Neutral foreground for noninteractive artwork and supporting symbols.
    static let decorativeSymbol = Color(nsColor: .secondaryLabelColor)
    static var sidebarBorder: Color { separatorTone.opacity(increasesContrast ? 1 : 0.90) }
    static var sidebarSeparator: Color { separatorTone.opacity(increasesContrast ? 1 : 0.75) }
    /// Zen's sidebar rule: a flat 10% black on light, 10% white on dark, not a
    /// system separator. From `light-dark(rgba(0, 0, 0, 0.1),
    /// rgba(255, 255, 255, 0.1))` on `.pinned-tabs-container-separator`.
    /// Raised to full strength under Increase Contrast like its neighbours.
    static var zenHairline: Color {
        increasesContrast ? separatorTone : Color.primary.opacity(0.1)
    }
    /// Zen's scrolled-edge rule on the tab list, a shade lighter than the
    /// pinned hairline: `--zen-scrollbar-overflow-background:
    /// light-dark(rgba(0, 0, 0, 0.08), rgba(255, 255, 255, 0.08))`.
    /// The drop indicator's tone: AppKit's own muted label grey. A blend of
    /// the accent still read as a coloured mark; this is the same semantic
    /// colour the system uses for secondary chrome, so it follows the
    /// appearance and Increase Contrast without a palette of our own.
    static var sidebarDropIndicator: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static var zenScrollEdgeRule: Color {
        increasesContrast ? separatorTone : Color.primary.opacity(0.08)
    }
    static var sidebarControlFill: Color { subtleTone.opacity(increasesContrast ? 1 : 0.72) }
    static var sidebarControlFillHover: Color { subtleTone.opacity(increasesContrast ? 1 : 0.96) }
    static var sidebarControlFillDropTarget: Color { tertiaryTone.opacity(increasesContrast ? 1 : 0.72) }
    /// Zen's selected-tab fill: neutral white, not the accent —
    /// `--tab-background-color-selected: light-dark(rgba(255,255,255,0.85),
    /// rgba(255,255,255,0.2))`. The accent-tinted fill this replaces is what
    /// read as a blue glow on every selected row.
    static var sidebarControlFillActive: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.2)
                : NSColor.white.withAlphaComponent(0.85)
        })
    }
    /// A split pane's chip when it is not the focused one. The same pill as
    /// `sidebarControlFillActive`, just quieter: leaving it clear made the
    /// focused chip look like a tab sitting *inside* the other one rather
    /// than the two halves of one row.
    static var sidebarSplitChipFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.09)
                : NSColor.white.withAlphaComponent(0.55)
        })
    }

    /// Zen's row shape on macOS: `--border-radius-medium: 12px`.
    static let sidebarRowCornerRadius: CGFloat = 12
    static var sidebarControlStroke: Color { separatorTone.opacity(increasesContrast ? 1 : 0.80) }
    static var spaceSetupInputFill: Color {
        spaceSetupSecondaryFill
    }
    static var spaceSetupSecondaryFill: Color {
        subtleTone.opacity(increasesContrast ? 1 : 0.42)
    }
    static var spaceSetupControlStroke: Color { separatorTone.opacity(increasesContrast ? 1 : 0.82) }
    static var spaceSetupPillFill: Color {
        tertiaryTone.opacity(increasesContrast ? 0.64 : 0.40)
    }
    /// The person's own messages carry the primary action treatment: the
    /// dynamic macOS accent (never a hard-coded brand blue), paired with the
    /// same white foreground the system uses on prominent accent-filled
    /// controls so text stays legible for every accent choice, including
    /// Graphite and multicolor, in both appearances. Assistant messages and
    /// Space themes keep their neutral treatments.
    static var userMessageFill: Color { AppColor.accent }
    static var userMessageText: Color { Color(nsColor: .alternateSelectedControlTextColor) }

    /// Transient feedback floats above content using a system material rather
    /// than turning the current Space identity color into an interaction color.
    static var feedbackText: Color { Color(nsColor: .labelColor) }
    static var feedbackButtonFill: Color {
        subtleTone.opacity(increasesContrast ? 1 : 0.72)
    }
    static var feedbackButtonFillHover: Color {
        subtleTone.opacity(increasesContrast ? 1 : 0.96)
    }
    static var updateBannerFill: Color { subtleTone.opacity(increasesContrast ? 1 : 0.92) }
    static var updateBannerFillHover: Color { tertiaryTone.opacity(increasesContrast ? 1 : 0.48) }
    static var updateBannerStroke: Color { separatorTone }
    static var sidebarText: Color { Color(nsColor: .labelColor) }
    static var sidebarTextSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var sidebarIcon: Color {
        Color(nsColor: increasesContrast ? .secondaryLabelColor : .tertiaryLabelColor)
    }
    static var windowControlInactive: Color { tertiaryTone.opacity(increasesContrast ? 1 : 0.58) }
    static let surfaceFill = Color(nsColor: .controlBackgroundColor)
    static var surfaceBorder: Color { separatorTone.opacity(increasesContrast ? 1 : 0.90) }
    static let popoverBackground = Color(nsColor: .windowBackgroundColor)
    static var popoverBorder: Color { separatorTone.opacity(increasesContrast ? 1 : 0.85) }

    private static var subtleTone: Color { Color(nsColor: .quaternaryLabelColor) }
    private static var tertiaryTone: Color { Color(nsColor: .tertiaryLabelColor) }
    private static var separatorTone: Color { Color(nsColor: .separatorColor) }

    private static var increasesContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Whether interface text needs to be dark to stay legible on the themed
    /// surface. At preview strength the theme color dominates the interface
    /// (0.74 tint), so the color's own perceived luminance decides: light
    /// colors (mint, gold, pink…) wash out white text.
    static func prefersDarkForeground(forSpaceHex hex: String) -> Bool {
        prefersDarkForeground(forSpaceHexes: [hex])
    }

    static func prefersDarkForeground(forSpaceHexes hexes: [String]) -> Bool {
        SpaceThemeReadability.resolved(for: hexes).usesDarkForeground
    }
}

internal struct SpaceThemeReadability {
    let usesDarkForeground: Bool
    let overlayOpacity: Double

    var overlayColor: Color {
        usesDarkForeground ? .white : .black
    }

    static func resolved(for hexes: [String]) -> Self {
        guard let palette = SpaceThemePalette.resolvedHexes(from: hexes) else {
            return Self(usesDarkForeground: false, overlayOpacity: 0)
        }

        let luminances = palette.compactMap(relativeLuminance)
        guard let darkest = luminances.min(), let lightest = luminances.max() else {
            return Self(usesDarkForeground: false, overlayOpacity: 0)
        }

        // WCAG's 4.5:1 target for ordinary text. Instead of assuming a
        // brightness threshold, solve for the smallest neutral overlay that
        // makes every generated theme color support one foreground.
        let minimumLightBackgroundLuminance = 4.5 * 0.05 - 0.05
        let maximumDarkBackgroundLuminance = 1.05 / 4.5 - 0.05

        let whiteOverlay = darkest >= minimumLightBackgroundLuminance
            ? 0
            : (minimumLightBackgroundLuminance - darkest) / (1 - darkest)
        let blackOverlay = lightest <= maximumDarkBackgroundLuminance
            ? 0
            : 1 - maximumDarkBackgroundLuminance / lightest

        if whiteOverlay < blackOverlay {
            return Self(usesDarkForeground: true, overlayOpacity: whiteOverlay)
        }
        if blackOverlay < whiteOverlay {
            return Self(usesDarkForeground: false, overlayOpacity: blackOverlay)
        }

        let average = luminances.reduce(0, +) / Double(luminances.count)
        return Self(
            usesDarkForeground: average >= 0.179,
            overlayOpacity: whiteOverlay
        )
    }

    private static func relativeLuminance(hex: String) -> Double? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }

        let red = linearized(Double((value >> 16) & 0xFF) / 255)
        let green = linearized(Double((value >> 8) & 0xFF) / 255)
        let blue = linearized(Double(value & 0xFF) / 255)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

/// The shared interface surface painted behind the browser workspace. Space
/// tint remains visible around the web surface while chrome such as the
/// sidebar can keep its own semantic background.
