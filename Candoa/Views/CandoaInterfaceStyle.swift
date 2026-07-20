import AppKit
import SwiftUI

enum CandoaColor {
    enum Apple {
        /// Reference value for persisting an explicitly selected blue Space.
        /// App interface colors use `NSColor.systemBlue` so they remain adaptive.
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
        static var selectedControlText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    }

    static let primaryHex = Apple.systemBlueReferenceHex
    static var primary: Color { Apple.controlAccent }
    static var primaryForeground: Color { Apple.selectedControlText }
    static var primaryHover: Color {
        let accent = NSColor.controlAccentColor
        let contrast = NSColor.labelColor
        return Color(nsColor: accent.blended(withFraction: 0.12, of: contrast) ?? accent)
    }
    static var focusRing: Color { primary.opacity(0.58) }
    static var selectedFill: Color { primary.opacity(0.16) }
    static var success: Color { Apple.systemGreen }
    static var warning: Color { Apple.systemOrange }
    static var danger: Color { Apple.systemRed }
}

enum CandoaInterfaceStyle {
    static let sidebarWidth: CGFloat = 234
    static var setupNeutralTint: Color { subtleTone }
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let workspaceBackground = Color(nsColor: .controlBackgroundColor)
    static var neutralWindowBackdrop: some View {
        workspaceBackground
            .overlay {
                LinearGradient(
                    colors: [shadowTone.opacity(0.04), shadowTone.opacity(0.07)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static var sidebarSurfaceOverlay: Color {
        shadowTone.opacity(increasesContrast ? 0.085 : 0.045)
    }
    static var sidebarBorder: Color { separatorTone.opacity(increasesContrast ? 1 : 0.90) }
    static var sidebarSeparator: Color { separatorTone.opacity(increasesContrast ? 1 : 0.75) }
    static var sidebarControlFill: Color { subtleTone.opacity(increasesContrast ? 1 : 0.72) }
    static var sidebarControlFillHover: Color { subtleTone.opacity(increasesContrast ? 1 : 0.96) }
    static var sidebarControlFillDropTarget: Color { tertiaryTone.opacity(increasesContrast ? 1 : 0.72) }
    static var sidebarControlFillActive: Color { CandoaColor.selectedFill }
    static var sidebarControlStroke: Color { separatorTone.opacity(increasesContrast ? 1 : 0.80) }
    static var spaceSetupInputFill: Color {
        increasesContrast ? tertiaryTone.opacity(0.56) : subtleTone.opacity(0.82)
    }
    static var spaceSetupSecondaryFill: Color {
        subtleTone.opacity(increasesContrast ? 1 : 0.42)
    }
    static var spaceSetupControlStroke: Color { separatorTone.opacity(increasesContrast ? 1 : 0.82) }
    static var spaceSetupPillFill: Color {
        tertiaryTone.opacity(increasesContrast ? 0.64 : 0.40)
    }
    static var neutralPrimaryFill: Color {
        Color(nsColor: .labelColor).opacity(increasesContrast ? 0.80 : 0.64)
    }
    static var neutralPrimaryText: Color {
        windowBackground
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
    private static var shadowTone: Color { Color(nsColor: .shadowColor) }

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

/// The shared interface surface painted across the window. Space tint remains
/// continuous through the sidebar, title-bar strip, and web-view gutter;
/// individual interface regions can add a restrained semantic tonal layer above it.
