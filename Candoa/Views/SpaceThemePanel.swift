import AppKit
import SwiftUI

internal struct SpaceThemePanel: View {
    @Binding var selectedHex: String?
    @Binding var selectedAppearance: SpaceThemeAppearance
    @Binding var selectedOpacity: Double
    @Binding var selectedTexture: Double
    let themeOptions: [(name: String, hex: String)]
    let onThemePreviewChange: ([String], Double, Double) -> Void

    @State private var auxiliaryHexes: [String] = []
    @State private var palettePage = 0
    @State private var palettePageDirection = 1
    @State private var usesHarmony = true
    @State private var dotPositions = [ThemeDotPosition(x: 0.57, y: 0.55)]
    @State private var didInitializeDotPositions = false

    private var paletteOptions: [(name: String, hex: String)] {
        themeOptions + [
            ("Mist", "#C8D3E8"),
            ("Mint", "#8BE0C2"),
            ("Amber", "#F0C36D"),
            ("Coral", "#F18A7A"),
            ("Lavender", "#C9A7E8"),
            ("Sky", "#82C4EA"),
            ("Rose", "#E4A4C3"),
            ("Graphite", "#8F96A8")
        ]
    }

    private var visiblePaletteOptions: [(name: String, hex: String)] {
        let pageSize = 8
        let currentPage = min(max(0, palettePage), pageCount - 1)
        let start = min(currentPage * pageSize, max(0, paletteOptions.count - pageSize))
        let end = min(start + pageSize, paletteOptions.count)
        return Array(paletteOptions[start..<end])
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(paletteOptions.count) / 8.0)))
    }

    private var canPagePaletteBackward: Bool {
        palettePage > 0
    }

    private var canPagePaletteForward: Bool {
        palettePage < pageCount - 1
    }

    private var activeHexes: [String] {
        selectedHex.map { [$0] + auxiliaryHexes } ?? []
    }

    private var normalizedOpacity: Double {
        (min(0.9, max(0.3, selectedOpacity)) - 0.3) / 0.6
    }

    private var hasSelectedThemeColor: Bool {
        selectedHex != nil
    }

    private var themeControlAccentHex: String {
        selectedHex ?? "#A8ADB7"
    }

    var body: some View {
        VStack(spacing: 0) {
            themeField

            paletteRow
                .padding(.top, 10)

            lowerControls
                .padding(.top, 12)
        }
        .padding(10)
        .frame(width: 372)
        .onAppear {
            initializeDotPositionsIfNeeded()
            publishThemePreview()
        }
        .onChange(of: selectedHex) { _, _ in
            publishThemePreview()
        }
        .onChange(of: auxiliaryHexes) { _, _ in
            publishThemePreview()
        }
        .onChange(of: selectedOpacity) { _, _ in
            publishThemePreview()
        }
        .onChange(of: selectedTexture) { _, _ in
            publishThemePreview()
        }
    }

    private var themeField: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))

            ThemeColorFieldBackground(
                hexes: activeHexes,
                positions: dotPositions,
                intensity: 0.20 + normalizedOpacity * 0.62
            )
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            DotPattern(opacity: 0.09 + selectedTexture * 0.22, spacing: 6, dotSize: 1.7)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            ThemeColorFieldDots(
                hexes: activeHexes,
                positions: dotPositions,
                onDrag: updateDotPosition
            )

            VStack(spacing: 0) {
                appearanceControls
                    .padding(.top, 12)

                Spacer(minLength: 0)

                fieldActionControls
                    .padding(.bottom, 15)
            }
        }
        .frame(height: 352)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
        }
    }

    private var appearanceControls: some View {
        HStack(spacing: 18) {
            ForEach(SpaceThemeAppearance.allCases) { option in
                Button {
                    selectedAppearance = option
                } label: {
                    Image(systemName: option.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 32)
                        .foregroundStyle(CandoaInterfaceStyle.sidebarText)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selectedAppearance == option ? Color.primary.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
        }
    }

    private var fieldActionControls: some View {
        HStack(spacing: 28) {
            ThemeIconButton(systemName: "plus", help: "Add Color") {
                addAuxiliaryColor()
            }
            .disabled(auxiliaryHexes.count >= 2)

            ThemeIconButton(systemName: "minus", help: "Remove Color") {
                removeAuxiliaryColor()
            }
            .disabled(selectedHex == nil && auxiliaryHexes.isEmpty)

            ThemeHarmonyButton(isActive: usesHarmony, isEnabled: activeHexes.count > 1) {
                usesHarmony.toggle()

                // Snap immediately so the toggle gives visible feedback
                // instead of only applying on the next dot drag.
                if usesHarmony, let primary = dotPositions.first, !auxiliaryHexes.isEmpty {
                    withAnimation(.easeOut(duration: 0.22)) {
                        harmonizeAuxiliaryDots(around: primary)
                    }
                    publishThemePreview()
                }
            }
        }
    }

    private var paletteRow: some View {
        HStack(spacing: 9) {
            ThemeIconButton(systemName: "chevron.left", help: "Previous Colors") {
                pagePalette(by: -1)
            }
            .disabled(!canPagePaletteBackward)

            ZStack {
                paletteColorPage
                    .id(palettePage)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: palettePageDirection > 0 ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: palettePageDirection > 0 ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                    )
            }
            .frame(width: 287, height: 32)
            .clipped()

            ThemeIconButton(systemName: "chevron.right", help: "More Colors") {
                pagePalette(by: 1)
            }
            .disabled(!canPagePaletteForward)
        }
        .frame(height: 32)
    }

    private var paletteColorPage: some View {
        HStack(spacing: 9) {
            ForEach(visiblePaletteOptions, id: \.hex) { option in
                Button {
                    selectPaletteColor(option.hex)
                } label: {
                    Circle()
                        .fill(Color(spaceHex: option.hex))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selectedHex == option.hex ? Color.white : Color.clear,
                                    lineWidth: 3
                                )
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selectedHex == option.hex ? CandoaInterfaceStyle.sidebarText.opacity(0.68) : Color.clear,
                                    lineWidth: 1
                                )
                                .padding(-1)
                        }
                }
                .buttonStyle(.plain)
                .help(option.name)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 287, height: 32, alignment: .leading)
    }

    private var lowerControls: some View {
        HStack(spacing: 18) {
            ThemeWaveSlider(
                value: $selectedOpacity,
                accentHex: themeControlAccentHex,
                isEnabled: hasSelectedThemeColor
            )
                .frame(width: 218, height: 58)

            Spacer(minLength: 0)

            ThemeTextureDial(
                value: $selectedTexture,
                accentHex: themeControlAccentHex,
                isEnabled: hasSelectedThemeColor
            )
                .frame(width: 62, height: 62)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func addAuxiliaryColor() {
        guard auxiliaryHexes.count < 2 else { return }
        let hexes = paletteOptions.map(\.hex)
        guard let firstHex = hexes.first else { return }

        if selectedHex == nil {
            selectedHex = firstHex
            ensureDotPositionCount()
            dotPositions[0] = Self.position(forHex: firstHex)
            publishThemePreview()
            return
        }

        let referenceHex = auxiliaryHexes.last ?? selectedHex ?? firstHex
        let referenceIndex = hexes.firstIndex(of: referenceHex) ?? 0

        for offset in 1...hexes.count {
            let candidate = hexes[(referenceIndex + offset) % hexes.count]
            if candidate != selectedHex, !auxiliaryHexes.contains(candidate) {
                auxiliaryHexes.append(candidate)
                ensureDotPositionCount()
                dotPositions[auxiliaryHexes.count] = suggestedAuxiliaryPosition(at: auxiliaryHexes.count)
                publishThemePreview()
                return
            }
        }
    }

    private func removeAuxiliaryColor() {
        if !auxiliaryHexes.isEmpty {
            auxiliaryHexes.removeLast()
        } else if selectedHex != nil {
            selectedHex = nil
        } else {
            return
        }

        if dotPositions.count > activeHexes.count {
            dotPositions.removeLast(dotPositions.count - activeHexes.count)
        }
        publishThemePreview()
    }

    private func initializeDotPositionsIfNeeded() {
        guard !didInitializeDotPositions else { return }
        didInitializeDotPositions = true
        dotPositions = selectedHex.map { [Self.position(forHex: $0)] } ?? []
        ensureDotPositionCount()
    }

    private func ensureDotPositionCount() {
        while dotPositions.count < activeHexes.count {
            dotPositions.append(suggestedAuxiliaryPosition(at: dotPositions.count))
        }

        if dotPositions.count > activeHexes.count {
            dotPositions.removeLast(dotPositions.count - activeHexes.count)
        }
    }

    private func selectPaletteColor(_ hex: String) {
        selectedHex = hex
        ensureDotPositionCount()
        dotPositions[0] = Self.position(forHex: hex)
        publishThemePreview()
    }

    private func pagePalette(by delta: Int) {
        let nextPage = min(max(0, palettePage + delta), pageCount - 1)
        guard nextPage != palettePage else { return }

        palettePageDirection = delta >= 0 ? 1 : -1
        withAnimation(.easeOut(duration: 0.18)) {
            palettePage = nextPage
        }
    }

    private func updateDotPosition(index: Int, position: ThemeDotPosition) {
        ensureDotPositionCount()
        guard dotPositions.indices.contains(index) else { return }

        dotPositions[index] = position

        if index == 0 {
            selectedHex = Self.hex(for: position)
            if usesHarmony, auxiliaryHexes.count > 0 {
                harmonizeAuxiliaryDots(around: position)
            }
        } else {
            let auxiliaryIndex = index - 1
            if auxiliaryHexes.indices.contains(auxiliaryIndex) {
                auxiliaryHexes[auxiliaryIndex] = Self.hex(for: position)
            }
        }

        publishThemePreview()
    }

    private func harmonizeAuxiliaryDots(around primaryPosition: ThemeDotPosition) {
        let dx = primaryPosition.x - 0.5
        let dy = primaryPosition.y - 0.5
        let primaryAngle = atan2(dy, dx)
        let radius = min(0.38, max(0.18, hypot(dx, dy)))

        for auxiliaryIndex in auxiliaryHexes.indices {
            let dotIndex = auxiliaryIndex + 1
            let offset = auxiliaryIndex == 0 ? 2.12 : -2.12
            let angle = primaryAngle + offset
            let position = ThemeDotPosition(
                x: 0.5 + cos(angle) * radius,
                y: 0.5 + sin(angle) * radius
            ).clampedToUnitCircle()

            dotPositions[dotIndex] = position
            auxiliaryHexes[auxiliaryIndex] = Self.hex(for: position)
        }
    }

    private func publishThemePreview() {
        onThemePreviewChange(activeHexes, selectedOpacity, selectedTexture)
    }

    private func suggestedAuxiliaryPosition(at index: Int) -> ThemeDotPosition {
        let primary = dotPositions.first ?? ThemeDotPosition(x: 0.57, y: 0.55)
        let dx = primary.x - 0.5
        let dy = primary.y - 0.5
        let primaryAngle = atan2(dy, dx)
        let radius = min(0.38, max(0.22, hypot(dx, dy)))
        let offset = index == 1 ? 2.12 : -2.12

        return ThemeDotPosition(
            x: 0.5 + cos(primaryAngle + offset) * radius,
            y: 0.5 + sin(primaryAngle + offset) * radius
        ).clampedToUnitCircle()
    }

    private static func position(forHex hex: String) -> ThemeDotPosition {
        guard let components = rgbComponents(from: hex) else {
            return ThemeDotPosition(x: 0.57, y: 0.55)
        }

        let color = NSColor(
            calibratedRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let radius = min(0.40, max(0.16, saturation * 0.40))
        let angle = hue * .pi * 2
        return ThemeDotPosition(
            x: 0.5 + cos(angle) * radius,
            y: 0.5 + sin(angle) * radius
        ).clampedToUnitCircle()
    }

    private static func hex(for position: ThemeDotPosition) -> String {
        let dx = position.x - 0.5
        let dy = position.y - 0.5
        var hue = atan2(dy, dx) / (.pi * 2)
        if hue < 0 {
            hue += 1
        }

        let distance = min(1, hypot(dx, dy) / 0.42)
        let saturation = min(0.96, max(0.34, distance))
        let brightness = min(0.98, max(0.46, 1.04 - position.y * 0.56))

        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            return BrowserSpace.blueThemeColorHex
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func rgbComponents(from hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }

        return (
            red: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0
        )
    }
}
