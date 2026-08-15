import AppKit
import SwiftUI

/// Owns the NSSharingServicePicker presentation and reports back when the
/// user picks a service or dismisses the popover.
@MainActor
final class SharePickerCoordinator: NSObject, NSSharingServicePickerDelegate {
    weak var anchorView: NSView?
    private var picker: NSSharingServicePicker?
    private var onDismiss: (() -> Void)?

    /// Shares a URL, handing AppKit the page's own title and site icon when
    /// the caller knows them.
    ///
    /// A bare URL leaves the sheet's link preview to LinkPresentation, which
    /// fetches the page before it can draw: the sheet opens with an empty
    /// header and the icon and title drop in a second or two later, resizing
    /// it — the flicker people saw on slow sites. The tab already holds both,
    /// so the preview can be right on the first frame with no network trip.
    func present(
        url: URL,
        title: String? = nil,
        faviconData: Data? = nil,
        onDismiss: @escaping () -> Void
    ) {
        guard picker == nil, let anchorView else {
            onDismiss()
            return
        }
        self.onDismiss = onDismiss
        let picker = NSSharingServicePicker(items: [Self.shareItem(url: url, title: title, faviconData: faviconData)])
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// The shared item stays the URL — services receive exactly what they did
    /// before; the wrapper only carries the preview AppKit would otherwise go
    /// fetch. With neither title nor icon to offer, the plain URL keeps the
    /// system's own (slower) preview rather than an empty one.
    private static func shareItem(url: URL, title: String?, faviconData: Data?) -> Any {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        let icon = faviconData.flatMap(NSImage.init(data:))

        guard previewTitle != nil || icon != nil else { return url }

        return NSPreviewRepresentingActivityItem(
            item: url,
            title: previewTitle,
            image: nil,
            icon: icon
        )
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
