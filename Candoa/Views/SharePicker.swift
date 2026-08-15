import AppKit
import SwiftUI

/// Owns the NSSharingServicePicker presentation and reports back when the
/// user picks a service or dismisses the popover.
@MainActor
final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    weak var anchorView: NSView?
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
struct SharePickerAnchor: NSViewRepresentable {
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
