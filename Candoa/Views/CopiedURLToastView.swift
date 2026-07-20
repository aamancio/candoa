import AppKit
import SwiftUI

struct CopiedURLToast: Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: URL
}

/// Zen/Arc-style confirmation pill shown when the current URL is copied.
/// Geometry and styling mirror Zen's `.zen-toast` (zen-popup.css): anchored
/// 8px from the window's top-right corner, 48px tall, 10px radius, a vertical
/// gradient from the space tint down to the tint mixed 20% toward near-black.
/// The share glyph is a live button that opens the macOS share picker for the
/// copied URL, anchored below the toast like Zen's.
struct CopiedURLToastView: View {
    let toast: CopiedURLToast
    let themeColorHex: String?
    /// Reports when the share picker opens/closes so the owner can pause the
    /// auto-dismiss timer for the duration.
    let onShareInteractionChanged: (Bool) -> Void

    @State private var sharePicker = SharePickerCoordinator()
    @State private var isShareHovered = false

    /// Zen's `--zen-element-separation` default — inset from the window edges.
    static let windowEdgeSpacing: CGFloat = 8

    // Arc's default purple, used when the space has no theme color.
    private static let fallbackTint = (red: 0.33, green: 0.23, blue: 0.55)

    private var tintComponents: (red: Double, green: Double, blue: Double) {
        guard let themeColorHex else { return Self.fallbackTint }
        let cleaned = themeColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            return Self.fallbackTint
        }
        return (
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    private var tint: Color {
        let rgb = tintComponents
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Zen: `color-mix(in srgb, var(--zen-primary-color), #0f0f0f 20%)`.
    private var tintDarkened: Color {
        let rgb = tintComponents
        let dark = Double(0x0F) / 255.0
        return Color(
            red: rgb.red * 0.8 + dark * 0.2,
            green: rgb.green * 0.8 + dark * 0.2,
            blue: rgb.blue * 0.8 + dark * 0.2
        )
    }

    private var prefersDarkForeground: Bool {
        guard let themeColorHex else { return false }
        return CandoaInterfaceStyle.prefersDarkForeground(forSpaceHex: themeColorHex)
    }

    private var foreground: Color {
        prefersDarkForeground ? Color.black.opacity(0.80) : .white
    }

    /// Zen button fill: `light-dark(rgba(255,255,255,0.5), rgba(255,255,255,0.1))`.
    private var glyphWellFill: Color {
        let base = prefersDarkForeground ? 0.5 : 0.1
        return Color.white.opacity(isShareHovered ? base + 0.08 : base)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, 4)

            Button {
                onShareInteractionChanged(true)
                sharePicker.present(url: toast.url) {
                    onShareInteractionChanged(false)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(glyphWellFill)
                    )
            }
            .buttonStyle(.plain)
            .background(SharePickerAnchor(coordinator: sharePicker))
            .onHover { isShareHovered = $0 }
            .accessibilityLabel("Share URL")
        }
        .padding(8)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint, tintDarkened],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .shadow(color: Color.black.opacity(0.25), radius: 11)
        .animation(.easeOut(duration: 0.10), value: isShareHovered)
    }
}

// MARK: - Share picker plumbing

/// Owns the NSSharingServicePicker presentation and reports back when the
/// user picks a service or dismisses the popover.
@MainActor
private final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    fileprivate weak var anchorView: NSView?
    private var picker: NSSharingServicePicker?
    private var onDismiss: (() -> Void)?

    func present(url: URL, onDismiss: @escaping () -> Void) {
        guard picker == nil, let anchorView else {
            onDismiss()
            return
        }
        self.onDismiss = onDismiss
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    nonisolated func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        Task { @MainActor in
            self.picker = nil
            let dismiss = self.onDismiss
            self.onDismiss = nil
            dismiss?()
        }
    }
}

/// Invisible NSView used as the popover anchor for the share picker.
private struct SharePickerAnchor: NSViewRepresentable {
    let coordinator: SharePickerCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        coordinator.anchorView = nsView
    }
}
