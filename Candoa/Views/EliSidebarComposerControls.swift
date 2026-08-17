import AppKit
import SwiftUI

struct AISidebarComposerIconButton: View {
    let symbolName: String
    let helpText: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foregroundStyle)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(backgroundFill)
                }
        }
        .buttonTreatment(.chrome)
        .disabled(!isEnabled)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var foregroundStyle: Color {
        guard isEnabled else { return InterfaceStyle.sidebarIcon.opacity(0.55) }
        return isHovered ? InterfaceStyle.sidebarTextSecondary : InterfaceStyle.sidebarIcon
    }

    private var backgroundFill: Color {
        guard isEnabled, isHovered else { return Color.clear }
        return InterfaceStyle.sidebarControlFillHover
    }
}

struct AISidebarComposerSendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(backgroundFill)
                }
        }
        .buttonTreatment(.chrome)
        .disabled(!isEnabled)
        .help("Send to Eli")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var iconColor: Color {
        isEnabled ? Color.black.opacity(0.88) : InterfaceStyle.sidebarIcon.opacity(0.58)
    }

    private var backgroundFill: Color {
        guard isEnabled else { return InterfaceStyle.sidebarControlFillHover }
        return isHovered ? Color.white.opacity(0.82) : Color.white.opacity(0.96)
    }
}

struct AISidebarSpeechWaveformView: View {
    private let levels: [CGFloat] = [
        0.12, 0.18, 0.10, 0.22, 0.34, 0.16, 0.42, 0.28, 0.58, 0.36,
        0.70, 0.30, 0.44, 0.24, 0.54, 0.20, 0.48, 0.34, 0.64, 0.26,
        0.40, 0.18, 0.32, 0.22, 0.52, 0.30, 0.46, 0.28, 0.68, 0.36,
        0.24, 0.20, 0.38, 0.18, 0.28, 0.14
    ]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(InterfaceStyle.sidebarTextSecondary.opacity(index % 5 == 0 ? 0.86 : 0.72))
                        .frame(width: 1.5, height: max(2, proxy.size.height * levels[index]))
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct AISidebarMentionButton: View {
    let title: String
    let detail: String?
    let symbolName: String
    let faviconData: Data?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AISidebarMentionIcon(
                    symbolName: symbolName,
                    faviconData: faviconData,
                    isSelected: isSelected,
                    size: 16
                )

                Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : InterfaceStyle.sidebarText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.72) : InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return AppColor.accent
        }

        return isHovered ? InterfaceStyle.sidebarControlFillHover : Color.clear
    }
}

/// A passage the person picked out of the page, shown above the composer as
/// a quote rather than beside the context chips. The chips say what Eli was
/// handed; the quote says which part of it the question is about, and reading
/// as one of the attachments was exactly the confusion this avoids.
struct AISidebarQuotedSelectionView: View {
    let selection: AISidebarSelectionContext
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.quotePreview)
                    .font(.system(size: 12))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 10, weight: .semibold))

                    Text(selection.sourceLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
            }

            Spacer(minLength: 0)

            // Held in the layout whether or not it is drawn, so the quote does
            // not reflow the moment the pointer crosses it.
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(InterfaceStyle.sidebarIcon)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonTreatment(.chrome)
            .help("Remove Quote")
            .accessibilityLabel("Remove quoted selection")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.leading, 11)
        // The rule is drawn as an overlay rather than a sibling: a bare
        // Capsule has no height of its own and would stretch the composer to
        // whatever room the sidebar had going spare.
        .overlay(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(InterfaceStyle.sidebarTextSecondary.opacity(0.42))
                .frame(width: 2)
        }
        .padding(.top, 10)
        .padding(.trailing, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

struct AISidebarContextChipView: View {
    let chip: AISidebarContextChip
    let onPreview: (() -> Void)?
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isRemoveHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let onPreview, chip.previewImageData != nil {
                Button(action: onPreview) {
                    chipBody
                }
                .buttonTreatment(.content)
                .help("Preview Image")
                .accessibilityLabel("Preview attached image")
                .accessibilityIdentifier("agent-attachment-preview")
            } else {
                chipBody
            }

            if chip.isRemovable && isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isRemoveHovered ? Color.black.opacity(0.86) : Color.white.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(isRemoveHovered ? Color.white.opacity(0.96) : Color.white.opacity(0.22))
                        )
                }
                .buttonTreatment(.chrome)
                .offset(x: 8, y: -8)
                .help("Remove Context")
                .transition(.opacity)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.10)) {
                        isRemoveHovered = hovering
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
                if !hovering {
                    isRemoveHovered = false
                }
            }
        }
    }

    private var chipBody: some View {
        HStack(spacing: 8) {
            chipIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !chip.subtitle.isEmpty {
                    Text(chip.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 130, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 42)
        .background(Color.primary.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(InterfaceStyle.sidebarControlStroke, lineWidth: 1)
        }
    }

    private var chipIcon: some View {
        AISidebarMentionIcon(
            symbolName: chip.symbolName,
            faviconData: chip.faviconData,
            previewImageData: chip.previewImageData,
            size: chip.previewImageData == nil ? 22 : 34
        )
        .frame(width: chip.previewImageData == nil ? 28 : 36, height: 36)
    }
}

struct AISidebarMentionIcon: View {
    let symbolName: String
    var faviconData: Data?
    var previewImageData: Data? = nil
    var isSelected = false
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let previewImageData, let image = NSImage(data: previewImageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Attachment preview")
            } else if let faviconData, let image = NSImage(data: faviconData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size < 20 ? 3.5 : 5, style: .continuous))
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: min(15, size * 0.78), weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.86) : InterfaceStyle.sidebarIcon)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The quote as it reads back in the transcript, under the same rule as the
/// composer block but sized to sit above the sent bubble.
struct AISidebarSentQuotedSelectionView: View {
    let selection: AISidebarSelectionContext

    var body: some View {
        Text(selection.quotePreview)
            .font(.system(size: 11))
            .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 9)
            .overlay(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(InterfaceStyle.sidebarTextSecondary.opacity(0.42))
                    .frame(width: 2)
            }
            .frame(maxWidth: 300, alignment: .leading)
    }
}

struct AISidebarSentContextChipView: View {
    let chip: AISidebarContextChip

    var body: some View {
        HStack(spacing: 6) {
            AISidebarMentionIcon(
                symbolName: chip.symbolName,
                faviconData: chip.faviconData,
                previewImageData: chip.previewImageData,
                size: 22
            )
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(chip.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(1)

                if !chip.subtitle.isEmpty {
                    Text(chip.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: 150, alignment: .leading)
        .background(InterfaceStyle.sidebarControlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
