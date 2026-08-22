import AppKit
import SwiftUI

struct AISidebarExamplePromptButton: View {
    let title: String
    let symbolName: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
                .foregroundStyle(InterfaceStyle.sidebarText.opacity(isEnabled ? 1 : 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isHovered && isEnabled
                                ? InterfaceStyle.sidebarControlFillHover
                                : InterfaceStyle.sidebarControlFill
                        )
                }
        }
        .buttonTreatment(.content)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct AISidebarTopBarIconButton: View {
    let symbolName: String
    let helpText: String
    var iconSize: CGFloat = 15
    var shortcut: ShortcutDefinition?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(InterfaceStyle.sidebarIcon.opacity(isHovered ? 0.92 : 0.72))
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? InterfaceStyle.sidebarControlFillHover : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonTreatment(.content)
        // The sidebar container's identifier cascades over child identifiers,
        // so the help text doubles as the stable accessibility handle.
        .accessibilityLabel(helpText)
        .shortcutTooltip(helpText, shortcut: shortcut)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }
}

/// Wraps AppKit's `NSButton` so the response actions use the system's native
/// tooltip mechanism even inside the SwiftUI chat scroll view.
internal struct AISidebarNativeIconButton: NSViewRepresentable {
    let symbolName: String
    let toolTip: String
    let accessibilityLabel: String
    let identifier: String
    var isSelected = false
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> AISidebarTooltipButton {
        let button = AISidebarTooltipButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.performAction)
        configure(button)
        return button
    }

    func updateNSView(_ button: AISidebarTooltipButton, context: Context) {
        context.coordinator.action = action
        configure(button)
    }

    private func configure(_ button: AISidebarTooltipButton) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        button.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        button.tooltipText = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(isSelected ? "selected" : "not selected")
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

/// Keeps the native AppKit tooltip hit region aligned with the button after
/// SwiftUI assigns or changes the representable's bounds.
internal final class AISidebarTooltipButton: NSButton, NSViewToolTipOwner {
    var tooltipText = "" {
        didSet {
            guard tooltipText != oldValue else { return }
            updateToolTipRect()
        }
    }

    private var tooltipTag: NSView.ToolTipTag?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateToolTipRect()
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipText
    }

    private func updateToolTipRect() {
        if let tooltipTag {
            removeToolTip(tooltipTag)
            self.tooltipTag = nil
        }

        guard !tooltipText.isEmpty, !bounds.isEmpty else { return }
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }
}
