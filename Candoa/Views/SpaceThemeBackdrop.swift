import AppKit
import SwiftUI

struct CandoaWindowBackdrop: View {
    @ObservedObject var store: BrowserStore

    private var hasThemeTint: Bool {
        !store.activeThemeColorHexes.isEmpty
    }

    private var isSetupThemePreviewActive: Bool {
        store.isSpaceSetupPresented && store.editingSpaceID == nil && hasThemeTint
    }

    private var usesSetupInterface: Bool {
        store.isSpaceSetupPresented && store.editingSpaceID == nil
    }

    private var backdropIntensity: Double {
        // Near-flat during preview: the gradient's brightened leading
        // blob sits under the sidebar and visibly whitens it otherwise.
        isSetupThemePreviewActive ? 0.04 : 0.08
    }

    // During create/initial setup theme preview the workspace mirrors
    // SpaceSetupCanvas's fill. While browsing, the chosen theme is the
    // chrome surface itself (Zen-style), scaled by the space's intensity
    // dial and capped so neutral sidebar foregrounds stay legible.
    private var spaceTintOpacity: Double {
        guard hasThemeTint else { return 0 }
        if usesSetupInterface {
            return 0.74
        }
        return min(0.52, 0.38 * store.activeThemeIntensityMultiplier)
    }

    private var setupReadability: SpaceThemeReadability {
        SpaceThemeReadability.resolved(for: store.activeThemeColorHexes)
    }

    var body: some View {
        ZStack {
            // Opaque base so this backdrop resolves the same wherever it is
            // drawn, instead of compositing over whatever sits beneath it.
            // underPageBackgroundColor is translucent in light appearance.
            Color(nsColor: .windowBackgroundColor)
            CandoaInterfaceStyle.neutralWindowBackdrop
            if let themeHex = store.activeThemeColorHexes.first {
                Color(spaceHex: themeHex)
                    .opacity(spaceTintOpacity)
            }
            if usesSetupInterface {
                SpaceThemeBackdrop(
                    hexes: store.activeThemeColorHexes,
                    intensity: backdropIntensity * store.activeThemeIntensityMultiplier,
                    texture: store.activeThemeTexture
                )
                if isSetupThemePreviewActive, setupReadability.overlayOpacity > 0 {
                    setupReadability.overlayColor.opacity(setupReadability.overlayOpacity)
                }
            } else if store.activeThemeTexture > 0 {
                // Browsing chrome is deliberately flat — a single uniform
                // color at every point of the window, so the sidebar lanes
                // and the center frame can never drift apart. Positioned
                // gradient blobs would reintroduce edge-to-edge variation.
                DotPattern(
                    opacity: 0.025 + min(1, max(0, store.activeThemeTexture)) * 0.12,
                    spacing: 5,
                    dotSize: 1.2
                )
                .blendMode(.overlay)
            }
        }
        .compositingGroup()
    }
}

/// Opaque stand-in for the shared window backdrop, used only while a sidebar
/// overlays the web surface. Docked sidebars draw no backdrop of their own so
/// the one window-wide surface shows through and both lanes match the center
/// exactly.
struct CandoaSidebarBackdrop: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        CandoaWindowBackdrop(store: store)
    }
}

struct SpaceThemeBackdrop: View {
    let hexes: [String]
    var intensity: Double = 1
    var texture: Double = 0

    private var palette: [String]? {
        SpaceThemePalette.resolvedHexes(from: hexes)
    }

    private var clampedTexture: Double {
        min(1, max(0, texture))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let longestSide = max(size.width, size.height)

            if let palette {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(spaceHex: palette[0]).opacity(0.34 * intensity),
                            Color(spaceHex: palette[1]).opacity(0.30 * intensity),
                            Color(spaceHex: palette[2]).opacity(0.42 * intensity)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    radialColor(hex: palette[0], opacity: 0.50 * intensity, endRadius: longestSide * 0.48)
                        .frame(width: longestSide * 0.95, height: longestSide * 0.95)
                        .position(x: size.width * 0.08, y: size.height * 0.18)
                        .blur(radius: 34)

                    radialColor(hex: palette[1], opacity: 0.38 * intensity, endRadius: longestSide * 0.54)
                        .frame(width: longestSide, height: longestSide)
                        .position(x: size.width * 0.52, y: size.height * 0.38)
                        .blur(radius: 42)

                    radialColor(hex: palette[2], opacity: 0.54 * intensity, endRadius: longestSide * 0.56)
                        .frame(width: longestSide * 1.05, height: longestSide * 1.05)
                        .position(x: size.width * 0.96, y: size.height * 0.52)
                        .blur(radius: 48)

                    if clampedTexture > 0 {
                        DotPattern(
                            opacity: 0.025 + clampedTexture * 0.12,
                            spacing: 5,
                            dotSize: 1.2
                        )
                        .blendMode(.overlay)
                    }
                }
            }
        }
        .compositingGroup()
    }

    private func radialColor(hex: String, opacity: Double, endRadius: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(spaceHex: hex).opacity(opacity),
                        Color(spaceHex: hex).opacity(opacity * 0.28),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 12,
                    endRadius: endRadius
                )
            )
    }
}

internal enum SpaceThemePalette {
    static func resolvedHexes(from hexes: [String]) -> [String]? {
        let cleaned = hexes.filter { !$0.isEmpty }
        guard let primary = cleaned.first else { return nil }

        if cleaned.count >= 3 {
            return Array(cleaned.prefix(3))
        }

        if cleaned.count == 2 {
            return [cleaned[0], shiftedHex(from: cleaned[0], hueOffset: 0.10, saturationScale: 0.72, brightnessScale: 1.08), cleaned[1]]
        }

        return [
            shiftedHex(from: primary, hueOffset: -0.015, saturationScale: 1.08, brightnessScale: 1.08),
            primary,
            shiftedHex(from: primary, hueOffset: 0.045, saturationScale: 0.72, brightnessScale: 0.92)
        ]
    }

    private static func shiftedHex(
        from hex: String,
        hueOffset: CGFloat,
        saturationScale: CGFloat,
        brightnessScale: CGFloat
    ) -> String {
        guard let color = nsColor(from: hex) else {
            return BrowserSpace.blueThemeColorHex
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let shiftedHue = (hue + hueOffset).truncatingRemainder(dividingBy: 1)
        let normalizedHue = shiftedHue < 0 ? shiftedHue + 1 : shiftedHue
        let shiftedColor = NSColor(
            calibratedHue: normalizedHue,
            saturation: min(0.94, max(0.16, saturation * saturationScale)),
            brightness: min(0.98, max(0.24, brightness * brightnessScale)),
            alpha: 1
        )

        guard let rgbColor = shiftedColor.usingColorSpace(.sRGB) else {
            return hex
        }

        return String(
            format: "#%02X%02X%02X",
            Int(round(rgbColor.redComponent * 255)),
            Int(round(rgbColor.greenComponent * 255)),
            Int(round(rgbColor.blueComponent * 255))
        )
    }

    private static func nsColor(from hex: String) -> NSColor? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }

        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
