import AppKit
import SwiftUI

struct CopiedURLToast: Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: URL
}

/// Native confirmation surface shown when the current URL is copied. The
/// current Space may tint the passive window backdrop, but transient feedback
/// remains a neutral material so it doesn't compete with the macOS accent.
struct CopiedURLToastView: View {
    let toast: CopiedURLToast
    /// Reports when the share picker opens/closes so the owner can pause the
    /// auto-dismiss timer for the duration.
    let onShareInteractionChanged: (Bool) -> Void

    @State private var sharePicker = SharePickerCoordinator()
    @State private var isShareHovered = false

    /// Zen's `--zen-element-separation` default — inset from the window edges.
    static let windowEdgeSpacing: CGFloat = 8

    private var glyphWellFill: Color {
        isShareHovered
            ? InterfaceStyle.feedbackButtonFillHover
            : InterfaceStyle.feedbackButtonFill
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(InterfaceStyle.feedbackText)
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
                    .foregroundStyle(InterfaceStyle.feedbackText)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(glyphWellFill)
                    )
            }
            .buttonTreatment(.content)
            .background(SharePickerAnchor(coordinator: sharePicker))
            .onHover { isShareHovered = $0 }
            .accessibilityLabel("Share URL")
        }
        .padding(8)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(InterfaceStyle.popoverBorder, lineWidth: 1)
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.20), radius: 11)
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
