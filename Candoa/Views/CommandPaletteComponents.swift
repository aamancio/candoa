import AppKit
import SwiftUI

internal struct PaletteBackground: View {
    var body: some View {
        InterfaceStyle.popoverBackground
    }
}

internal struct CommandPaletteKeyMonitor: NSViewRepresentable {
    let isProviderChipDeletable: Bool
    let onDeleteProviderChip: () -> Void
    let onMoveSelection: (Int) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isProviderChipDeletable: isProviderChipDeletable,
            onDeleteProviderChip: onDeleteProviderChip,
            onMoveSelection: onMoveSelection,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitorIfNeeded()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isProviderChipDeletable = isProviderChipDeletable
        context.coordinator.onDeleteProviderChip = onDeleteProviderChip
        context.coordinator.onMoveSelection = onMoveSelection
        context.coordinator.onCancel = onCancel
        context.coordinator.installMonitorIfNeeded()
    }

    final class Coordinator {
        var isProviderChipDeletable: Bool
        var onDeleteProviderChip: () -> Void
        var onMoveSelection: (Int) -> Void
        var onCancel: () -> Void
        private var monitor: Any?

        init(
            isProviderChipDeletable: Bool,
            onDeleteProviderChip: @escaping () -> Void,
            onMoveSelection: @escaping (Int) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.isProviderChipDeletable = isProviderChipDeletable
            self.onDeleteProviderChip = onDeleteProviderChip
            self.onMoveSelection = onMoveSelection
            self.onCancel = onCancel
        }

        func installMonitorIfNeeded() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }

                if Self.isPlainEscape(event) {
                    onCancel()
                    return nil
                }

                if let delta = Self.selectionDelta(for: event) {
                    onMoveSelection(delta)
                    return nil
                }

                guard
                    isProviderChipDeletable,
                    Self.isPlainDelete(event)
                else {
                    return event
                }

                onDeleteProviderChip()
                return nil
            }
        }

        /// Up/Down arrows and the standard Control-P/Control-N field-editor
        /// bindings move the result selection, matching Arc and Zen.
        private static func selectionDelta(for event: NSEvent) -> Int? {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])

            if modifiers.isEmpty {
                switch event.keyCode {
                case 125: return 1   // Down Arrow
                case 126: return -1  // Up Arrow
                default: return nil
                }
            }

            if modifiers == .control {
                switch event.keyCode {
                case 45: return 1    // Control-N
                case 35: return -1   // Control-P
                default: return nil
                }
            }

            return nil
        }

        private static func isPlainEscape(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
            return modifiers.isEmpty && event.keyCode == 53
        }

        private static func isPlainDelete(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.subtracting(.capsLock).isEmpty else { return false }
            return event.keyCode == 51 || event.keyCode == 117
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

internal struct PaletteCommandRow: View {
    let command: PaletteCommand
    let isSelected: Bool
    let selectedTint: Color
    @State internal var isHovering = false

    private var shortcutKeys: [String] { command.shortcutKeys }

    // Arc keeps the selection highlight one constant accent everywhere;
    // provider brand colors belong on the chip, never on the selected row.
    private var backgroundColor: Color {
        if isSelected {
            return selectedTint
        }

        return isHovering ? Color.primary.opacity(0.10) : Color.clear
    }

    var body: some View {
        HStack(spacing: 12) {
            PaletteIconView(
                symbolName: command.symbolName,
                isSelected: isSelected,
                size: 24,
                faviconData: command.faviconData,
                faviconPageURL: command.faviconPageURL,
                provider: command.provider
            )

            // The title wins the width fight; a long address gives way in
            // its middle ("localhost:8080/em…ber/details") as Arc's rows do.
            Text(command.title)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let detail = command.detail, !detail.isEmpty {
                Text("— \(detail)")
                    .foregroundStyle(isSelected ? Color.white.opacity(0.68) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // No "— History" / "— Tab" / "— Search" tag: Arc's rows are
            // favicon, title and address only. The source still reaches
            // VoiceOver through the row's accessibility label.

            Spacer(minLength: 12)

            if command.showsSwitchToTab {
                Text("Switch to Tab")
                    .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.secondary)
                    .lineLimit(1)
            } else if !shortcutKeys.isEmpty {
                // Same one-cap-per-key treatment as the hover tooltip pill,
                // so the palette teaches shortcuts the way the chrome does.
                HStack(spacing: 3) {
                    ForEach(Array(shortcutKeys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.secondary)
                            .frame(minWidth: 20)
                            .frame(height: 20)
                            .padding(.horizontal, key.count > 1 ? 4 : 0)
                            .background(
                                isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            )
                    }
                }
            }
        }
        .font(.system(size: 13.5, weight: .semibold))
        .padding(.horizontal, 12)
        .frame(height: 46)
        .contentShape(Rectangle())
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("command-row-\(commandPaletteAccessibilitySlug(command.title))")
    }
}

internal struct PaletteIconView: View {
    let symbolName: String
    let isSelected: Bool
    let size: CGFloat
    var faviconData: Data? = nil
    var faviconPageURL: URL? = nil
    var usesCircularFavicon = false
    var provider: SearchProvider? = nil
    @State internal var loadedFaviconData: Data?

    var body: some View {
        Group {
            if let faviconImage {
                faviconImageView(faviconImage)
            } else if let provider {
                providerIcon(provider)
            } else if symbolName == "google" {
                googleIcon
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.68, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
                    .frame(width: size, height: size)
            }
        }
        .task(id: faviconPageURL) {
            guard faviconData == nil,
                  loadedFaviconData == nil,
                  let faviconPageURL
            else {
                return
            }

            loadedFaviconData = await FaviconService.shared.faviconData(for: faviconPageURL, candidateURL: nil)
        }
    }

    private var faviconImage: NSImage? {
        (faviconData ?? loadedFaviconData).flatMap(NSImage.init(data:))
    }

    @ViewBuilder
    private func faviconImageView(_ image: NSImage) -> some View {
        let icon = Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .padding(isSelected ? size * 0.14 : 0)
            .frame(width: size, height: size)
            .background(isSelected || usesCircularFavicon ? Color.white : Color.clear)

        if usesCircularFavicon {
            icon.clipShape(Circle())
        } else {
            icon.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    @ViewBuilder
    private var googleIcon: some View {
        let icon = GoogleGMark()
            .frame(width: size * 0.72, height: size * 0.72)
            .frame(width: size, height: size)
            .background(Color.white)

        if usesCircularFavicon {
            icon.clipShape(Circle())
        } else {
            icon.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    // x.com ships a black tile with a white mark; selected rows flip to the
    // white tile every other favicon gets so the glyph stays readable.
    @ViewBuilder
    private var xIcon: some View {
        let icon = XBrandMark()
            .fill(isSelected ? Color.black : Color.white, style: FillStyle(eoFill: true))
            .frame(width: size * 0.52, height: size * 0.52)
            .frame(width: size, height: size)
            .background(isSelected ? Color.white : Color.black)

        if usesCircularFavicon {
            icon.clipShape(Circle())
        } else {
            icon.clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    @ViewBuilder
    private func providerIcon(_ provider: SearchProvider) -> some View {
        switch provider.id {
        case "google":
            googleIcon
        case "youtube":
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                    .frame(width: size * 0.95, height: size * 0.68)

                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.31, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 1)
            }
            .frame(width: size, height: size)
        case "amazon":
            AmazonBrandMark()
                .fill(Color(red: 1.0, green: 0.60, blue: 0.0))
                .frame(width: size, height: size)
            .frame(width: size, height: size)
        case "reddit":
            RedditBrandMark(isSelected: isSelected, size: size)
                .frame(width: size, height: size)
        case "x":
            xIcon
        case "github":
            GitHubBrandMark()
                .fill(isSelected ? Color.white : Color.primary)
                .frame(width: size * 0.86, height: size * 0.86)
                .frame(width: size, height: size)
        case "spotify":
            SpotifyBrandMark()
                .fill(
                    isSelected ? Color.white : Color(red: 0.11, green: 0.73, blue: 0.33),
                    style: FillStyle(eoFill: true)
                )
                .frame(width: size * 0.92, height: size * 0.92)
                .frame(width: size, height: size)
        default:
            Image(systemName: provider.symbolName)
                .font(.system(size: size * 0.68, weight: .medium))
                .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                .frame(width: size, height: size)
        }
    }
}

internal struct AmazonBrandMark: Shape {
    private static let pathData = "M.045 18.02c.072-.116.187-.124.348-.022 3.636 2.11 7.594 3.166 11.87 3.166 2.852 0 5.668-.533 8.447-1.595l.315-.14c.138-.06.234-.1.293-.13.226-.088.39-.046.525.13.12.174.09.336-.12.48-.256.19-.6.41-1.006.654-1.244.743-2.64 1.316-4.185 1.726a17.617 17.617 0 01-10.951-.577 17.88 17.88 0 01-5.43-3.35c-.1-.074-.151-.15-.151-.22 0-.047.021-.09.051-.13zm6.565-6.218c0-1.005.247-1.863.743-2.577.495-.71 1.17-1.25 2.04-1.615.796-.335 1.756-.575 2.912-.72.39-.046 1.033-.103 1.92-.174v-.37c0-.93-.105-1.558-.3-1.875-.302-.43-.78-.65-1.44-.65h-.182c-.48.046-.896.196-1.246.46-.35.27-.575.63-.675 1.096-.06.3-.206.465-.435.51l-2.52-.315c-.248-.06-.372-.18-.372-.39 0-.046.007-.09.022-.15.247-1.29.855-2.25 1.82-2.88.976-.616 2.1-.975 3.39-1.05h.54c1.65 0 2.957.434 3.888 1.29.135.15.27.3.405.48.12.165.224.314.283.45.075.134.15.33.195.57.06.254.105.42.135.51.03.104.062.3.076.615.01.313.02.493.02.553v5.28c0 .376.06.72.165 1.036.105.313.21.54.315.674l.51.674c.09.136.136.256.136.36 0 .12-.06.226-.18.314-1.2 1.05-1.86 1.62-1.963 1.71-.165.135-.375.15-.63.045a6.062 6.062 0 01-.526-.496l-.31-.347a9.391 9.391 0 01-.317-.42l-.3-.435c-.81.886-1.603 1.44-2.4 1.665-.494.15-1.093.227-1.83.227-1.11 0-2.04-.343-2.76-1.034-.72-.69-1.08-1.665-1.08-2.94l-.05-.076zm3.753-.438c0 .566.14 1.02.425 1.364.285.34.675.512 1.155.512.045 0 .106-.007.195-.02.09-.016.134-.023.166-.023.614-.16 1.08-.553 1.424-1.178.165-.28.285-.58.36-.91.09-.32.12-.59.135-.8.015-.195.015-.54.015-1.005v-.54c-.84 0-1.484.06-1.92.18-1.275.36-1.92 1.17-1.92 2.43l-.035-.02zm9.162 7.027c.03-.06.075-.11.132-.17.362-.243.714-.41 1.05-.5a8.094 8.094 0 011.612-.24c.14-.012.28 0 .41.03.65.06 1.05.168 1.172.33.063.09.099.228.099.39v.15c0 .51-.149 1.11-.424 1.8-.278.69-.664 1.248-1.156 1.68-.073.06-.14.09-.197.09-.03 0-.06 0-.09-.012-.09-.044-.107-.12-.064-.24.54-1.26.806-2.143.806-2.64 0-.15-.03-.27-.087-.344-.145-.166-.55-.257-1.224-.257-.243 0-.533.016-.87.046-.363.045-.7.09-1 .135-.09 0-.148-.014-.18-.044-.03-.03-.036-.047-.02-.077 0-.017.006-.03.02-.063v-.06z"

    func path(in rect: CGRect) -> Path {
        SVGPathData(pathData: Self.pathData).path(in: rect)
    }
}

internal struct XBrandMark: Shape {
    private static let pathData = "M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0 1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z"

    func path(in rect: CGRect) -> Path {
        SVGPathData(pathData: Self.pathData).path(in: rect)
    }
}

internal struct GitHubBrandMark: Shape {
    private static let pathData = "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"

    func path(in rect: CGRect) -> Path {
        SVGPathData(pathData: Self.pathData).path(in: rect)
    }
}

internal struct SpotifyBrandMark: Shape {
    private static let pathData = "M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0m5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02m1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2m.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3"

    func path(in rect: CGRect) -> Path {
        SVGPathData(pathData: Self.pathData).path(in: rect)
    }
}

internal struct RedditBrandMark: View {
    let isSelected: Bool
    let size: CGFloat

    private var orange: Color {
        Color(red: 1.00, green: 0.27, blue: 0.05)
    }

    private var markColor: Color {
        isSelected ? .white : orange
    }

    var body: some View {
        ZStack {
            if !isSelected {
                Circle()
                    .fill(orange)
                    .frame(width: size * 0.92, height: size * 0.92)
            }

            ZStack {
                Circle()
                    .fill(isSelected ? .white : Color.white)
                    .frame(width: size * 0.54, height: size * 0.42)
                    .offset(y: size * 0.08)

                Circle()
                    .fill(markColor)
                    .frame(width: size * 0.08, height: size * 0.08)
                    .offset(x: -size * 0.14, y: size * 0.06)

                Circle()
                    .fill(markColor)
                    .frame(width: size * 0.08, height: size * 0.08)
                    .offset(x: size * 0.14, y: size * 0.06)

                Capsule()
                    .fill(markColor)
                    .frame(width: size * 0.18, height: size * 0.035)
                    .offset(y: size * 0.17)

                Capsule()
                    .fill(isSelected ? .white : Color.white)
                    .frame(width: size * 0.25, height: size * 0.07)
                    .rotationEffect(.degrees(-28))
                    .offset(x: size * 0.11, y: -size * 0.16)

                Circle()
                    .fill(isSelected ? .white : Color.white)
                    .frame(width: size * 0.12, height: size * 0.12)
                    .offset(x: size * 0.24, y: -size * 0.27)

                Circle()
                    .fill(isSelected ? .white : Color.white)
                    .frame(width: size * 0.15, height: size * 0.15)
                    .offset(x: -size * 0.32, y: size * 0.08)

                Circle()
                    .fill(isSelected ? .white : Color.white)
                    .frame(width: size * 0.15, height: size * 0.15)
                    .offset(x: size * 0.32, y: size * 0.08)
            }
        }
    }
}

internal struct GoogleGMark: View {
    var body: some View {
        ZStack {
            GoogleGPath(path: blueGooglePath)
                .fill(Color(red: 0.26, green: 0.52, blue: 0.96))
            GoogleGPath(path: greenGooglePath)
                .fill(Color(red: 0.20, green: 0.66, blue: 0.33))
            GoogleGPath(path: yellowGooglePath)
                .fill(Color(red: 0.98, green: 0.74, blue: 0.02))
            GoogleGPath(path: redGooglePath)
                .fill(Color(red: 0.92, green: 0.26, blue: 0.21))
        }
    }

    private var blueGooglePath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 22.56, y: 12.25))
        path.addCurve(to: CGPoint(x: 22.36, y: 10), control1: CGPoint(x: 22.56, y: 11.47), control2: CGPoint(x: 22.49, y: 10.72))
        path.addLine(to: CGPoint(x: 12, y: 10))
        path.addLine(to: CGPoint(x: 12, y: 14.26))
        path.addLine(to: CGPoint(x: 17.92, y: 14.26))
        path.addCurve(to: CGPoint(x: 15.71, y: 17.57), control1: CGPoint(x: 17.66, y: 15.63), control2: CGPoint(x: 16.88, y: 16.79))
        path.addLine(to: CGPoint(x: 15.71, y: 20.34))
        path.addLine(to: CGPoint(x: 19.28, y: 20.34))
        path.addCurve(to: CGPoint(x: 22.56, y: 12.25), control1: CGPoint(x: 21.36, y: 18.42), control2: CGPoint(x: 22.56, y: 15.6))
        path.closeSubpath()
        return path
    }

    private var greenGooglePath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 23))
        path.addCurve(to: CGPoint(x: 19.28, y: 20.34), control1: CGPoint(x: 14.97, y: 23), control2: CGPoint(x: 17.46, y: 22.02))
        path.addLine(to: CGPoint(x: 15.71, y: 17.57))
        path.addCurve(to: CGPoint(x: 12, y: 18.63), control1: CGPoint(x: 14.73, y: 18.23), control2: CGPoint(x: 13.48, y: 18.63))
        path.addCurve(to: CGPoint(x: 5.84, y: 14.1), control1: CGPoint(x: 9.14, y: 18.63), control2: CGPoint(x: 6.71, y: 16.7))
        path.addLine(to: CGPoint(x: 2.18, y: 14.1))
        path.addLine(to: CGPoint(x: 2.18, y: 16.94))
        path.addCurve(to: CGPoint(x: 12, y: 23), control1: CGPoint(x: 3.99, y: 20.53), control2: CGPoint(x: 7.7, y: 23))
        path.closeSubpath()
        return path
    }

    private var yellowGooglePath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 5.84, y: 14.09))
        path.addCurve(to: CGPoint(x: 5.49, y: 12), control1: CGPoint(x: 5.62, y: 13.43), control2: CGPoint(x: 5.49, y: 12.73))
        path.addCurve(to: CGPoint(x: 5.84, y: 9.91), control1: CGPoint(x: 5.49, y: 11.27), control2: CGPoint(x: 5.62, y: 10.57))
        path.addLine(to: CGPoint(x: 5.84, y: 7.07))
        path.addLine(to: CGPoint(x: 2.18, y: 7.07))
        path.addCurve(to: CGPoint(x: 1, y: 12), control1: CGPoint(x: 1.43, y: 8.55), control2: CGPoint(x: 1, y: 10.22))
        path.addCurve(to: CGPoint(x: 2.18, y: 16.93), control1: CGPoint(x: 1, y: 13.78), control2: CGPoint(x: 1.43, y: 15.45))
        path.addLine(to: CGPoint(x: 5.03, y: 14.71))
        path.addLine(to: CGPoint(x: 5.84, y: 14.09))
        path.closeSubpath()
        return path
    }

    private var redGooglePath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 5.38))
        path.addCurve(to: CGPoint(x: 16.21, y: 7.02), control1: CGPoint(x: 13.62, y: 5.38), control2: CGPoint(x: 15.06, y: 5.94))
        path.addLine(to: CGPoint(x: 19.36, y: 3.87))
        path.addCurve(to: CGPoint(x: 12, y: 1), control1: CGPoint(x: 17.45, y: 2.09), control2: CGPoint(x: 14.97, y: 1))
        path.addCurve(to: CGPoint(x: 2.18, y: 7.07), control1: CGPoint(x: 7.7, y: 1), control2: CGPoint(x: 3.99, y: 3.47))
        path.addLine(to: CGPoint(x: 5.84, y: 9.91))
        path.addCurve(to: CGPoint(x: 12, y: 5.38), control1: CGPoint(x: 6.71, y: 7.31), control2: CGPoint(x: 9.14, y: 5.38))
        path.closeSubpath()
        return path
    }
}

internal struct GoogleGPath: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let xOffset = rect.midX - 12 * scale
        let yOffset = rect.midY - 12 * scale
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: xOffset, ty: yOffset))
    }
}

internal struct SVGPathData {
    let pathData: String

    func path(in rect: CGRect) -> Path {
        var parser = Parser(pathData)
        let basePath = parser.parse()
        let scale = min(rect.width, rect.height) / 24
        let xOffset = rect.midX - 12 * scale
        let yOffset = rect.midY - 12 * scale
        return basePath.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: xOffset, ty: yOffset))
    }

    private struct Parser {
        let data: String
        var index: String.Index

        init(_ data: String) {
            self.data = data
            self.index = data.startIndex
        }

        mutating func parse() -> Path {
            var path = Path()
            var command: Character?
            var currentPoint = CGPoint.zero
            var subpathStart = CGPoint.zero
            var lastCubicControl: CGPoint?

            while !isAtEnd {
                skipSeparators()
                guard !isAtEnd else { break }
                let commandStartIndex = index

                if let next = peek, next.isSVGPathCommand {
                    command = readCharacter()
                }

                guard let command else { break }

                // Only C/c/S/s leave a reflectable control point behind; every
                // other command clears it so a following S starts from itself.
                if !"CcSs".contains(command) {
                    lastCubicControl = nil
                }

                switch command {
                case "M", "m":
                    var isFirstPoint = true
                    while let point = readPoint(relativeTo: command == "m" ? currentPoint : nil) {
                        if isFirstPoint {
                            path.move(to: point)
                            subpathStart = point
                            isFirstPoint = false
                        } else {
                            path.addLine(to: point)
                        }
                        currentPoint = point
                        if nextTokenIsCommand { break }
                    }
                case "L", "l":
                    while let point = readPoint(relativeTo: command == "l" ? currentPoint : nil) {
                        path.addLine(to: point)
                        currentPoint = point
                        if nextTokenIsCommand { break }
                    }
                case "H", "h":
                    while let x = readNumber() {
                        let point = CGPoint(x: command == "h" ? currentPoint.x + x : x, y: currentPoint.y)
                        path.addLine(to: point)
                        currentPoint = point
                        if nextTokenIsCommand { break }
                    }
                case "V", "v":
                    while let y = readNumber() {
                        let point = CGPoint(x: currentPoint.x, y: command == "v" ? currentPoint.y + y : y)
                        path.addLine(to: point)
                        currentPoint = point
                        if nextTokenIsCommand { break }
                    }
                case "C", "c":
                    while let control1 = readPoint(relativeTo: command == "c" ? currentPoint : nil),
                          let control2 = readPoint(relativeTo: command == "c" ? currentPoint : nil),
                          let point = readPoint(relativeTo: command == "c" ? currentPoint : nil) {
                        path.addCurve(to: point, control1: control1, control2: control2)
                        currentPoint = point
                        lastCubicControl = control2
                        if nextTokenIsCommand { break }
                    }
                case "S", "s":
                    while let control2 = readPoint(relativeTo: command == "s" ? currentPoint : nil),
                          let point = readPoint(relativeTo: command == "s" ? currentPoint : nil) {
                        let mirrored = lastCubicControl ?? currentPoint
                        let control1 = CGPoint(
                            x: 2 * currentPoint.x - mirrored.x,
                            y: 2 * currentPoint.y - mirrored.y
                        )
                        path.addCurve(to: point, control1: control1, control2: control2)
                        currentPoint = point
                        lastCubicControl = control2
                        if nextTokenIsCommand { break }
                    }
                case "A", "a":
                    while let point = readArcEndpoint(relativeTo: command == "a" ? currentPoint : nil) {
                        path.addLine(to: point)
                        currentPoint = point
                        if nextTokenIsCommand { break }
                    }
                case "Z", "z":
                    path.closeSubpath()
                    currentPoint = subpathStart
                default:
                    return path
                }

                if index == commandStartIndex {
                    return path
                }
            }

            return path
        }

        private var isAtEnd: Bool {
            index >= data.endIndex
        }

        private var peek: Character? {
            isAtEnd ? nil : data[index]
        }

        private var nextTokenIsCommand: Bool {
            var copy = self
            copy.skipSeparators()
            return copy.peek?.isSVGPathCommand == true
        }

        private mutating func readCharacter() -> Character {
            let character = data[index]
            index = data.index(after: index)
            return character
        }

        private mutating func readPoint(relativeTo origin: CGPoint?) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            if let origin {
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            return CGPoint(x: x, y: y)
        }

        private mutating func readArcEndpoint(relativeTo origin: CGPoint?) -> CGPoint? {
            let start = index
            guard
                readNumber() != nil,
                readNumber() != nil,
                readNumber() != nil,
                readArcFlag() != nil,
                readArcFlag() != nil,
                let x = readNumber(),
                let y = readNumber()
            else {
                index = start
                return nil
            }

            if let origin {
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            return CGPoint(x: x, y: y)
        }

        private mutating func readArcFlag() -> Int? {
            skipSeparators()
            guard let flag = peek, flag == "0" || flag == "1" else { return nil }
            _ = readCharacter()
            return flag == "1" ? 1 : 0
        }

        private mutating func readNumber() -> CGFloat? {
            skipSeparators()
            let start = index

            if peek == "-" || peek == "+" {
                _ = readCharacter()
            }

            var hasDigit = false
            while let character = peek, character.isNumber {
                hasDigit = true
                _ = readCharacter()
            }

            if peek == "." {
                _ = readCharacter()
                while let character = peek, character.isNumber {
                    hasDigit = true
                    _ = readCharacter()
                }
            }

            if peek == "e" || peek == "E" {
                let exponentStart = index
                _ = readCharacter()

                if peek == "-" || peek == "+" {
                    _ = readCharacter()
                }

                var hasExponentDigit = false
                while let character = peek, character.isNumber {
                    hasExponentDigit = true
                    _ = readCharacter()
                }

                if !hasExponentDigit {
                    index = exponentStart
                }
            }

            guard hasDigit else {
                index = start
                return nil
            }

            guard let value = Double(String(data[start..<index])) else { return nil }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while let character = peek, character == "," || character.isWhitespace {
                _ = readCharacter()
            }
        }
    }
}

internal extension Character {
    var isSVGPathCommand: Bool {
        switch self {
        case "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "A", "a", "Z", "z":
            true
        default:
            false
        }
    }
}

