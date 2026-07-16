import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window controls

@MainActor
internal struct SidebarRevealEffect: @MainActor AnimatableModifier {
    var progress: CGFloat
    let hiddenOffset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .transformEffect(CGAffineTransform(
                translationX: hiddenOffset * (1 - progress),
                y: 0
            ))
            .environment(\.sidebarRevealProgress, progress)
    }
}

private struct SidebarRevealProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private extension EnvironmentValues {
    var sidebarRevealProgress: CGFloat {
        get { self[SidebarRevealProgressKey.self] }
        set { self[SidebarRevealProgressKey.self] = newValue }
    }
}

internal struct WindowControlsView: View {
    @Environment(\.sidebarRevealProgress) private var revealProgress
    let hiddenOffset: CGFloat

    var body: some View {
        NativeWindowControlsView(
            revealProgress: revealProgress,
            hiddenOffset: hiddenOffset
        )
    }
}
internal struct NativeWindowControlsView: NSViewRepresentable {
    let revealProgress: CGFloat
    let hiddenOffset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NativeWindowControlsHost()
        view.configure(revealProgress: revealProgress, hiddenOffset: hiddenOffset)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NativeWindowControlsHost)?.configure(
            revealProgress: revealProgress,
            hiddenOffset: hiddenOffset
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeWindowControlsHost)?.restoreWindowControls()
    }
}

private final class NativeWindowControlsHost: NSView {
    private static let buttonTypes: [NSWindow.ButtonType] = [
        .closeButton,
        .miniaturizeButton,
        .zoomButton
    ]
    private static let fallbackButtonSize = NSSize(width: 14, height: 14)
    private weak var attachedWindow: NSWindow?
    private var originalFrames: [Int: NSRect] = [:]
    private var originalHiddenStates: [Int: Bool] = [:]
    private var revealProgress: CGFloat = 1
    private var hiddenOffset: CGFloat = 0
    private var attachmentGeneration = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindowControls()

        guard let window else { return }
        attachmentGeneration += 1
        let generation = attachmentGeneration

        // SwiftUI applies the hidden-title-bar style after representable views
        // attach. AppKit may rebuild the title-bar container in that pass, so
        // reclaim and position the same native buttons once the window chrome
        // has settled. This is a one-shot setup correction, not a timer.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  self.window === window,
                  self.attachmentGeneration == generation else { return }
            self.attachWindowControls()
        }
    }

    func configure(revealProgress: CGFloat, hiddenOffset: CGFloat) {
        self.revealProgress = min(max(revealProgress, 0), 1)
        self.hiddenOffset = hiddenOffset
        attachWindowControls()
    }

    func attachWindowControls() {
        guard let window else { return }

        if let attachedWindow, attachedWindow !== window {
            restoreWindowControls()
        }

        attachedWindow = window

        for buttonType in Self.buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            if originalFrames[key] == nil {
                originalFrames[key] = button.frame
                originalHiddenStates[key] = button.isHidden
            }
        }

        layoutWindowControls()
    }

    func restoreWindowControls() {
        guard let attachedWindow else { return }

        attachmentGeneration += 1

        for buttonType in Self.buttonTypes {
            guard let button = attachedWindow.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            if let originalFrame = originalFrames[key] {
                button.frame = originalFrame
            }

            if let wasHidden = originalHiddenStates[key] {
                button.isHidden = wasHidden
            }
        }

        originalFrames.removeAll()
        originalHiddenStates.removeAll()
        self.attachedWindow = nil
    }

    override func layout() {
        super.layout()
        layoutWindowControls()
    }

    private func layoutWindowControls() {
        guard let attachedWindow else { return }

        for buttonType in Self.buttonTypes {
            guard let button = attachedWindow.standardWindowButton(buttonType) else { continue }
            let key = Int(buttonType.rawValue)

            // The controls belong to the sidebar, not the web-content lane.
            // Keep AppKit as their owner and hide them at the landed closed
            // state so a later title-bar layout pass cannot expose them over
            // the active WKWebView.
            guard revealProgress > 0 else {
                button.isHidden = true
                continue
            }

            let currentSize = button.frame.size
            let buttonSize = currentSize.width > 0 && currentSize.height > 0
                ? currentSize
                : Self.fallbackButtonSize
            button.isHidden = false
            let originalFrame = originalFrames[key] ?? button.frame
            button.frame = NSRect(
                origin: CGPoint(
                    x: originalFrame.minX + hiddenOffset * (1 - revealProgress),
                    y: originalFrame.minY
                ),
                size: buttonSize
            )
        }
    }
}

// MARK: - Toolbar icon button

internal struct ToolbarIconButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .frame(width: 25, height: 25)
            .offset(y: -2)
            .contentShape(Rectangle())
    }
}

internal extension View {
    func toolbarIconButton() -> some View {
        modifier(ToolbarIconButtonModifier())
    }
}

// MARK: - Shared chrome styling

/// Candoa's semantic color tokens. Native controls follow the person's macOS
/// accent preference; explicit blue uses Apple's adaptable system blue.
enum CandoaColor {
    enum Apple {
        /// Reference value for persisting an explicitly selected blue Space.
        /// App chrome uses `NSColor.systemBlue` so it remains adaptive.
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
}

enum CandoaChromeStyle {
    static let sidebarWidth: CGFloat = 234
    static let setupNeutralTint = Color.primary.opacity(0.10)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let workspaceBackground = Color(nsColor: .controlBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor).opacity(0.90)
    static let sidebarBorder = Color.primary.opacity(0.12)
    static let sidebarSeparator = Color.primary.opacity(0.08)
    static let sidebarControlFill = Color.primary.opacity(0.055)
    static let sidebarControlFillHover = Color.primary.opacity(0.080)
    static let sidebarControlFillDropTarget = Color.primary.opacity(0.18)
    static var sidebarControlFillActive: Color { CandoaColor.selectedFill }
    static let sidebarControlStroke = Color.primary.opacity(0.08)
    static let spaceSetupControlFill = Color.primary.opacity(0.060)
    static let spaceSetupControlStroke = Color.primary.opacity(0.08)
    static let spaceSetupPillFill = Color.primary.opacity(0.075)
    static let updateBannerFill = Color.primary.opacity(0.075)
    static let updateBannerFillHover = Color.primary.opacity(0.105)
    static let updateBannerStroke = Color.primary.opacity(0.20)
    static let sidebarText = Color.primary.opacity(0.88)
    static let sidebarTextSecondary = Color.primary.opacity(0.62)
    static let sidebarIcon = Color.primary.opacity(0.38)
    static let windowControlInactive = Color.primary.opacity(0.14)
    static let surfaceFill = Color(nsColor: .controlBackgroundColor)
    static let surfaceBorder = Color.primary.opacity(0.12)
    static let popoverBackground = Color(nsColor: .windowBackgroundColor)
    static let popoverBorder = Color(nsColor: .separatorColor).opacity(0.85)

    /// Whether chrome text needs to be dark to stay legible on the themed
    /// surface. At preview strength the theme color dominates the chrome
    /// (0.74 tint), so the color's own perceived luminance decides: light
    /// colors (mint, gold, pink…) wash out white text.
    static func prefersDarkForeground(forSpaceHex hex: String) -> Bool {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return false }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0

        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.60
    }
}

/// The single chrome surface painted across the entire window (Zen-style):
/// sidebar, title-bar strip, and the gutter around the web view all share it,
/// so the theme tint reads as one continuous backdrop.
struct CandoaWindowBackdrop: View {
    @ObservedObject var store: BrowserStore

    private var hasThemeTint: Bool {
        !store.activeThemeColorHexes.isEmpty
    }

    private var isSetupThemePreviewActive: Bool {
        store.isSpaceSetupPresented && store.editingSpaceID == nil && hasThemeTint
    }

    private var usesSetupChrome: Bool {
        store.isSpaceSetupPresented && store.editingSpaceID == nil
    }

    private var backdropIntensity: Double {
        if usesSetupChrome {
            // Near-flat during preview: the gradient's brightened leading
            // blob sits under the sidebar and visibly whitens it otherwise.
            return isSetupThemePreviewActive ? 0.04 : 0.08
        }

        return 0.16
    }

    // During create/initial setup theme preview the chrome mirrors
    // SpaceSetupCanvas's fill so sidebar, title bar, and canvas read as one
    // continuous color. Editing keeps normal browsing chrome so preview and
    // saved state match.
    private var spaceTintOpacity: Double {
        guard hasThemeTint else { return 0 }
        return usesSetupChrome ? 0.74 : 0.050
    }

    var body: some View {
        ZStack {
            CandoaChromeStyle.windowBackground
            Color(spaceHex: store.activeThemeColorHexes.first ?? "#8A8F98")
                .opacity(spaceTintOpacity)
            SpaceThemeBackdrop(
                hexes: store.activeThemeColorHexes,
                intensity: backdropIntensity * store.activeThemeIntensityMultiplier,
                texture: store.activeThemeTexture
            )
            CandoaChromeStyle.setupNeutralTint.opacity(usesSetupChrome && !isSetupThemePreviewActive ? 0.18 : 0)
        }
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
            return BrowserSpace.defaultThemeColorHex
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

internal struct SidebarHorizontalDropLine: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(tint.opacity(0.92), lineWidth: 2)
                .background(
                    Circle()
                        .fill(CandoaChromeStyle.sidebarBackground)
                )
                .frame(width: 7, height: 7)

            Capsule(style: .continuous)
                .fill(tint.opacity(0.82))
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .offset(x: -1)
        }
        .frame(maxWidth: .infinity)
        .shadow(color: tint.opacity(0.22), radius: 3, y: 1)
        .allowsHitTesting(false)
    }
}

internal struct SidebarVerticalDropLine: View {
    let tint: Color

    var body: some View {
        Capsule(style: .continuous)
            .fill(tint.opacity(0.82))
            .frame(width: 2)
            .shadow(color: tint.opacity(0.22), radius: 3, x: 1)
            .allowsHitTesting(false)
    }
}

internal extension View {
    func sidebarRowDropIndicator(
        showsTop: Bool,
        showsSplit: Bool = false,
        showsBottom: Bool,
        tint: Color
    ) -> some View {
        overlay(alignment: .top) {
            if showsTop {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: -2)
            }
        }
        .overlay {
            if showsSplit {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CandoaChromeStyle.sidebarControlFillDropTarget)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.62), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottom {
                SidebarHorizontalDropLine(tint: tint)
                    .padding(.horizontal, 8)
                    .offset(y: 2)
            }
        }
    }

    func sidebarEssentialDropIndicator(
        showsLeading: Bool,
        showsTrailing: Bool,
        tint: Color
    ) -> some View {
        overlay(alignment: .leading) {
            if showsLeading {
                SidebarVerticalDropLine(tint: tint)
                    .padding(.vertical, 7)
                    .offset(x: -4)
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailing {
                SidebarVerticalDropLine(tint: tint)
                    .padding(.vertical, 7)
                    .offset(x: 4)
            }
        }
    }
}
