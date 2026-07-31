import AppKit
import SwiftUI

internal struct ThemeDotPosition: Equatable {
    var x: CGFloat
    var y: CGFloat

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    func clampedToUnitCircle() -> ThemeDotPosition {
        let dx = x - 0.5
        let dy = y - 0.5
        let radius = hypot(dx, dy)
        guard radius > 0.42 else {
            return ThemeDotPosition(
                x: min(0.92, max(0.08, x)),
                y: min(0.92, max(0.08, y))
            )
        }

        let scale = 0.42 / radius
        return ThemeDotPosition(
            x: min(0.92, max(0.08, 0.5 + dx * scale)),
            y: min(0.92, max(0.08, 0.5 + dy * scale))
        )
    }

    static func clamped(from point: CGPoint, in size: CGSize) -> ThemeDotPosition {
        let safeWidth = max(1, size.width)
        let safeHeight = max(1, size.height)
        let center = CGPoint(x: safeWidth / 2, y: safeHeight / 2)
        let fieldRadius = min(safeWidth, safeHeight) * 0.42
        var clampedPoint = point

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        if distance > fieldRadius {
            let scale = fieldRadius / distance
            clampedPoint = CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }

        return ThemeDotPosition(
            x: min(0.92, max(0.08, clampedPoint.x / safeWidth)),
            y: min(0.92, max(0.08, clampedPoint.y / safeHeight))
        )
    }
}

internal struct ThemeColorFieldBackground: View {
    let hexes: [String]
    let positions: [ThemeDotPosition]
    let intensity: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(hexes.enumerated()), id: \.offset) { index, hex in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(spaceHex: hex).opacity(intensity),
                                    Color(spaceHex: hex).opacity(intensity * 0.30),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 8,
                                endRadius: 125
                            )
                        )
                        .frame(width: 260, height: 260)
                        .position(position(for: index, in: proxy.size))
                        .blur(radius: 14)
                }

                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.08),
                        Color.primary.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        guard positions.indices.contains(index) else {
            return CGPoint(x: size.width * 0.57, y: size.height * 0.55)
        }

        return positions[index].point(in: size)
    }
}

internal struct ThemeColorFieldDots: View {
    let hexes: [String]
    let positions: [ThemeDotPosition]
    let onDrag: (Int, ThemeDotPosition) -> Void

    private static let coordinateSpaceName = "CandoaThemeColorField"

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(hexes.enumerated()), id: \.offset) { index, hex in
                    Circle()
                        .fill(Color(spaceHex: hex))
                        .frame(width: index == 0 ? 40 : 22, height: index == 0 ? 40 : 22)
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(index == 0 ? 0.95 : 0.86), lineWidth: index == 0 ? 5 : 3)
                        }
                        .shadow(color: Color.black.opacity(0.20), radius: 8, x: 0, y: 4)
                        .scaleEffect(positions.indices.contains(index) ? 1 : 0.001)
                        .position(position(for: index, in: proxy.size))
                        .contentShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                                .onChanged { gesture in
                                    onDrag(
                                        index,
                                        ThemeDotPosition.clamped(from: gesture.location, in: proxy.size)
                                    )
                                }
                        )
                        .help(index == 0 ? "Drag to change Space color" : "Drag to adjust theme color")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: Self.coordinateSpaceName)
        }
    }

    private func position(for index: Int, in size: CGSize) -> CGPoint {
        guard positions.indices.contains(index) else {
            return CGPoint(x: size.width * 0.57, y: size.height * 0.55)
        }

        return positions[index].point(in: size)
    }
}

internal struct ThemeIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarText.opacity(isEnabled ? 0.92 : 0.34))
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .candoaButton(.content)
        .help(help)
        .accessibilityLabel(help)
    }
}

internal struct ThemeHarmonyButton: View {
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var didPushNotAllowedCursor = false

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(CandoaInterfaceStyle.sidebarText.opacity(isEnabled ? (isActive ? 0.94 : 0.54) : 0.30))
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive && isEnabled ? Color.primary.opacity(0.13) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .candoaButton(.content)
        .help(isEnabled ? "Auto-arrange colors" : "Add another color to use harmony")
        .accessibilityLabel("Color Harmony")
        .onHover { hovering in
            isHovering = hovering
            updateCursor()
        }
        .onChange(of: isEnabled) { _, _ in
            updateCursor()
        }
        .onDisappear {
            popNotAllowedCursorIfNeeded()
        }
    }

    private func updateCursor() {
        guard isHovering, !isEnabled else {
            popNotAllowedCursorIfNeeded()
            return
        }

        guard !didPushNotAllowedCursor else { return }
        NSCursor.operationNotAllowed.push()
        didPushNotAllowedCursor = true
    }

    private func popNotAllowedCursorIfNeeded() {
        guard didPushNotAllowedCursor else { return }
        NSCursor.pop()
        didPushNotAllowedCursor = false
    }
}

internal struct ThemeWaveSlider: View {
    @Binding var value: Double
    let accentHex: String
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var handleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private let range = 0.3...0.9

    private var normalizedValue: Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let progress = normalizedValue
            let handleX = CGFloat(progress) * max(1, size.width - 26) + 13
            let handleWidth = CGFloat(14 + progress * 10)
            let handleHeight = CGFloat(42 + progress * 12)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isEnabled ? 0.09 : 0.05))
                    .frame(height: 16)
                    .padding(.horizontal, 1)

                ThemeWaveShape(progress: progress)
                    .stroke(Color.primary.opacity(isEnabled ? 0.28 : 0.16), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(height: 32)
                    .padding(.horizontal, 1)

                ThemeWaveShape(progress: progress)
                    .trim(from: 0, to: progress)
                    .stroke(
                        isEnabled
                            ? Color(spaceHex: accentHex).opacity(0.38 + progress * 0.46)
                            : Color.primary.opacity(0.12),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )
                    .frame(height: 32)
                    .padding(.horizontal, 1)

                Capsule(style: .continuous)
                    .fill(handleColor.opacity(isEnabled ? 1 : 0.28))
                    .frame(width: handleWidth, height: handleHeight)
                    .shadow(color: Color.black.opacity(isEnabled ? 0.22 : 0), radius: 6, x: 0, y: 3)
                    .position(x: handleX, y: size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let progress = min(1, max(0, gesture.location.x / max(1, size.width)))
                        value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}

internal struct ThemeWaveShape: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amplitude = rect.height * (0.18 + CGFloat(progress) * 0.20)
        let midY = rect.midY
        let wavelength = max(34, rect.width / 5.5)

        path.move(to: CGPoint(x: rect.minX, y: midY))

        var x = rect.minX
        while x <= rect.maxX {
            let normalized = (x - rect.minX) / wavelength
            let y = midY + sin(normalized * .pi * 2) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += 3
        }

        return path
    }
}

internal struct ThemeTextureDial: View {
    @Binding var value: Double
    let accentHex: String
    let isEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragValue: Double?

    private var handleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private let textureStepCount = 16
    private var maxTextureStep: Int {
        textureStepCount - 1
    }

    private var clampedValue: Double {
        min(1, max(0, value))
    }

    private var displayedValue: Double {
        dragValue ?? clampedValue
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side * 0.35
            let activeValue = displayedValue
            let activeStep = textureStep(for: activeValue)

            ZStack {
                ForEach(0..<textureStepCount, id: \.self) { index in
                    let isActive = isEnabled && activeValue > 0 && index <= activeStep
                    Circle()
                        .fill(isActive ? Color(spaceHex: accentHex).opacity(0.74) : Color.primary.opacity(index % 4 == 0 ? 0.30 : 0.20))
                        .frame(width: index % 4 == 0 ? 5 : 4, height: index % 4 == 0 ? 5 : 4)
                        .position(point(forStep: index, radius: radius, in: proxy.size))
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(spaceHex: accentHex).opacity(isEnabled ? 0.28 : 0.04),
                                Color.primary.opacity(isEnabled ? 0.10 : 0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        DotPattern(
                            opacity: isEnabled ? 0.03 + activeValue * 0.20 : 0.035,
                            spacing: 4,
                            dotSize: 1.1
                        )
                        .clipShape(Circle())
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .frame(width: side * 0.64, height: side * 0.64)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)

                Capsule(style: .continuous)
                    .fill(handleColor.opacity(isEnabled ? 1 : 0.34))
                    .frame(width: 7, height: 18)
                    .rotationEffect(.degrees(rotationDegrees(forStep: activeStep)))
                    .position(point(forStep: activeStep, radius: radius, in: proxy.size))
                    .shadow(color: Color.black.opacity(isEnabled ? 0.18 : 0), radius: 3, x: 0, y: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let nextValue = steppedValue(for: dialValue(for: gesture.location, in: proxy.size))
                        if textureStep(for: displayedValue) != textureStep(for: nextValue) {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                        setValueWithoutAnimation(nextValue)
                    }
                    .onEnded { _ in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            dragValue = nil
                        }
                    }
            )
        }
    }

    private func point(forStep step: Int, radius: CGFloat, in size: CGSize) -> CGPoint {
        let angle = angle(forStep: step)
        return CGPoint(
            x: size.width / 2 + sin(angle) * radius,
            y: size.height / 2 - cos(angle) * radius
        )
    }

    private func dialValue(for location: CGPoint, in size: CGSize) -> Double {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = normalizedAngle(atan2(location.y - center.y, location.x - center.x) + (.pi / 2))
        return Double(angle / (.pi * 2))
    }

    private func angle(forStep step: Int) -> CGFloat {
        CGFloat(min(maxTextureStep, max(0, step))) / CGFloat(textureStepCount) * .pi * 2
    }

    private func rotationDegrees(forStep step: Int) -> Double {
        Double(min(maxTextureStep, max(0, step))) / Double(textureStepCount) * 360
    }

    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        positiveModulo(angle, .pi * 2)
    }

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private func steppedValue(for value: Double) -> Double {
        Double(textureStep(for: value)) / Double(maxTextureStep)
    }

    private func textureStep(for value: Double) -> Int {
        min(maxTextureStep, max(0, Int((min(1, max(0, value)) * Double(maxTextureStep)).rounded())))
    }

    private func setValueWithoutAnimation(_ nextValue: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragValue = nextValue
            value = nextValue
        }
    }
}

internal struct DotPattern: View {
    var opacity: Double = 0.11
    var spacing: CGFloat = 8
    var dotSize: CGFloat = 2

    var body: some View {
        let clampedOpacity = min(1, max(0, opacity))

        if clampedOpacity > 0 {
            DotPatternCanvas(spacing: spacing, dotSize: dotSize)
                .equatable()
                .opacity(clampedOpacity)
        }
    }
}

internal struct DotPatternCanvas: View, Equatable {
    var spacing: CGFloat
    var dotSize: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard spacing > 0, dotSize > 0 else { return }

            var dots = Path()
            var x: CGFloat = 6
            while x < size.width {
                var y: CGFloat = 6
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
                    y += spacing
                }
                x += spacing
            }

            context.fill(dots, with: .color(Color.primary))
        }
    }
}
