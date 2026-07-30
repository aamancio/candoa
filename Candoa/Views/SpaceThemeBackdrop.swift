import AppKit
import SwiftUI

/// Blend state for the window chrome while a Space swipe is in flight.
/// The sidebar's swipe gesture writes it per frame; only the window backdrop
/// observes it, so the whole store isn't invalidated at gesture rate.
@MainActor
final class SpaceChromeTransition: ObservableObject {
    @Published private(set) var destinationSpaceID: UUID?
    @Published private(set) var fraction: Double = 0

    func update(fraction: Double, toward spaceID: UUID?) {
        if destinationSpaceID != spaceID {
            destinationSpaceID = spaceID
        }
        if self.fraction != fraction {
            self.fraction = fraction
        }
    }

    func reset() {
        update(fraction: 0, toward: nil)
    }
}

struct CandoaWindowBackdrop: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var chromeTransition: SpaceChromeTransition

    init(store: BrowserStore) {
        self._store = ObservedObject(wrappedValue: store)
        self._chromeTransition = ObservedObject(wrappedValue: store.chromeTransition)
    }

    private struct ResolvedTint {
        let color: NSColor
        let opacity: Double
    }

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

    /// The Space the chrome is currently blending toward, while a swipe is in
    /// flight. Nil once the switch commits (destination becomes active) or
    /// when nothing is transitioning, so the plain active theme applies.
    private var transitionDestinationSpace: BrowserSpace? {
        guard
            !usesSetupInterface,
            chromeTransition.fraction > 0,
            let destinationID = chromeTransition.destinationSpaceID,
            destinationID != store.activeSpaceID
        else {
            return nil
        }
        return store.spaces.first { $0.id == destinationID }
    }

    private var transitionFraction: Double {
        min(1, max(0, chromeTransition.fraction))
    }

    private func browsingTint(hex: String?, themeOpacity: Double) -> ResolvedTint? {
        guard let hex, let color = NSColor(spaceHex: hex) else { return nil }
        let multiplier = BrowserStore.themeIntensityMultiplier(forOpacity: themeOpacity)
        return ResolvedTint(color: color, opacity: min(0.52, 0.38 * multiplier))
    }

    /// Browsing tint with the in-flight swipe blend applied: the surface
    /// color follows the gesture between the two Spaces' themes instead of
    /// snapping when the switch commits.
    private var blendedChromeTint: ResolvedTint? {
        let source = browsingTint(
            hex: store.activeThemeColorHexes.first,
            themeOpacity: store.activeThemeOpacity
        )
        guard let destinationSpace = transitionDestinationSpace else { return source }

        let destination = browsingTint(
            hex: destinationSpace.themeColorHex,
            themeOpacity: destinationSpace.themeOpacity
        )
        let fraction = transitionFraction

        switch (source, destination) {
        case (nil, nil):
            return nil
        case (let source?, nil):
            return ResolvedTint(color: source.color, opacity: source.opacity * (1 - fraction))
        case (nil, let destination?):
            return ResolvedTint(color: destination.color, opacity: destination.opacity * fraction)
        case (let source?, let destination?):
            let color = source.color.blended(withFraction: fraction, of: destination.color)
            return ResolvedTint(
                color: color ?? destination.color,
                opacity: source.opacity + (destination.opacity - source.opacity) * fraction
            )
        }
    }

    private var chromeTexture: Double {
        let source = store.activeThemeTexture
        guard let destinationSpace = transitionDestinationSpace else { return source }
        return source + (destinationSpace.themeTexture - source) * transitionFraction
    }

    /// Crossfade theme changes that arrive without a gesture (keyboard or
    /// menu Space switches). Live setup/edit previews stay immediate so the
    /// theme dials track the pointer.
    private var animatesThemeChanges: Bool {
        !store.isSpaceSetupPresented && !store.isSpaceThemeColorPreviewActive
    }

    private var themeChangeSignature: [String] {
        store.activeThemeColorHexes + [
            String(store.activeThemeOpacity),
            String(store.activeThemeTexture)
        ]
    }

    var body: some View {
        ZStack {
            // Opaque base so this backdrop resolves the same wherever it is
            // drawn, instead of compositing over whatever sits beneath it.
            // underPageBackgroundColor is translucent in light appearance.
            Color(nsColor: .windowBackgroundColor)
            CandoaInterfaceStyle.neutralWindowBackdrop
            if usesSetupInterface {
                if let themeHex = store.activeThemeColorHexes.first {
                    Color(spaceHex: themeHex)
                        .opacity(spaceTintOpacity)
                }
                SpaceThemeBackdrop(
                    hexes: store.activeThemeColorHexes,
                    intensity: backdropIntensity * store.activeThemeIntensityMultiplier,
                    texture: store.activeThemeTexture
                )
                if isSetupThemePreviewActive, setupReadability.overlayOpacity > 0 {
                    setupReadability.overlayColor.opacity(setupReadability.overlayOpacity)
                }
            } else {
                if let tint = blendedChromeTint {
                    Color(nsColor: tint.color)
                        .opacity(tint.opacity)
                }
                if chromeTexture > 0 {
                    // Browsing chrome is deliberately flat — a single uniform
                    // color at every point of the window, so the sidebar lanes
                    // and the center frame can never drift apart. Positioned
                    // gradient blobs would reintroduce edge-to-edge variation.
                    DotPattern(
                        opacity: 0.025 + min(1, max(0, chromeTexture)) * 0.12,
                        spacing: 5,
                        dotSize: 1.2
                    )
                    .blendMode(.overlay)
                }
            }
        }
        .compositingGroup()
        .animation(
            animatesThemeChanges ? .easeInOut(duration: 0.28) : nil,
            value: themeChangeSignature
        )
    }
}

private extension NSColor {
    convenience init?(spaceHex: String) {
        let hex = spaceHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
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
