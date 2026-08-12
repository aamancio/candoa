import AppKit
import WebKit

/// WKWebView subclass that owns Candoa's additions to the web content
/// context menu. WebKit builds the menu itself; `willOpenMenu` is the only
/// supported hook, and WebKit's own items are recognizable by their
/// `WKMenuItemIdentifier…` identifiers.
final class BrowserWebView: WKWebView {
    private static let copyIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
    private static let shareIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierShareMenu")

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // A plain Copy item is WebKit's tell for a text selection (images and
        // links get Copy Image / Copy Link instead), which is the only context
        // where Safari offers its Notes shortcut.
        guard menu.items.contains(where: { $0.identifier == Self.copyIdentifier }),
              NotesSharingService.isAvailable else { return }

        let addNote = NSMenuItem(
            title: String(localized: "Add to Notes", comment: "Web context menu: send the selected text to the Notes app."),
            action: #selector(addSelectionToNotes(_:)),
            keyEquivalent: ""
        )
        addNote.target = self

        // Mirror Safari's placement: directly above the Share… item, in the
        // same group as the copy actions.
        if let shareIndex = menu.items.firstIndex(where: { $0.identifier == Self.shareIdentifier }) {
            menu.insertItem(addNote, at: shareIndex)
        } else {
            menu.addItem(addNote)
        }
    }

    @objc private func addSelectionToNotes(_ sender: NSMenuItem) {
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let selection = result as? String,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // One combined string, not [text, URL]: given a URL item the Notes
            // extension keeps only a link card and drops the text, so fold the
            // source link into the note body instead.
            var noteText = selection
            if let url = self.url { noteText += "\n\n— \(url.absoluteString)" }
            NotesSharingService.share(items: [noteText])
        }
    }
}

/// Locates the Notes share extension. `sharingServices(forItems:)` is
/// soft-deprecated in favor of NSSharingServicePicker, but the picker can
/// only present its own chooser UI — targeting one known service still
/// requires the enumeration API, so call it through the runtime in the same
/// probe-first style as the Web Inspector bridging.
enum NotesSharingService {
    static var isAvailable: Bool { locate(for: ["probe"]) != nil }

    static func share(items: [Any]) {
        locate(for: items)?.perform(withItems: items)
    }

    private static func locate(for items: [Any]) -> NSSharingService? {
        let selector = NSSelectorFromString("sharingServicesForItems:")
        let metaclass: AnyObject = NSSharingService.self
        guard metaclass.responds(to: selector),
              let services = metaclass.perform(selector, with: items)?
                .takeUnretainedValue() as? [NSSharingService] else { return nil }

        // The extension's menu title is the app's name in the system language,
        // so derive the needle the same way instead of hard-coding "Notes".
        let notesName = FileManager.default.displayName(atPath: "/System/Applications/Notes.app")
        return services.first { $0.menuItemTitle.localizedCaseInsensitiveContains(notesName) }
    }
}
