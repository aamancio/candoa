import AppKit
import WebKit

/// WKWebView subclass that owns Candoa's additions to the web content
/// context menu. WebKit builds the menu itself; `willOpenMenu` is the only
/// supported hook, and WebKit's own items are recognizable by their
/// `WKMenuItemIdentifier…` identifiers.
final class BrowserWebView: WKWebView {
    private static let copyIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
    private static let shareIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierShareMenu")
    private static let searchWebIdentifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")

    /// Set at registration; carries selection actions that need the store
    /// (opening tabs) out of the view layer.
    weak var coordinator: WebViewCoordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // WebKit's stock Search item hands the query to the system default
        // browser, leaving the app. Retarget it to search in a new tab here,
        // and let the title reflect the engine Candoa will actually use.
        if let searchItem = menu.items.first(where: { $0.identifier == Self.searchWebIdentifier }) {
            if let providerName = coordinator?.defaultSearchProviderName {
                searchItem.title = String(
                    localized: "Search with \(providerName)",
                    comment: "Web context menu: search the selected text with the default engine, e.g. Google."
                )
            }
            searchItem.target = self
            searchItem.action = #selector(searchWebForSelection(_:))
        }

        // A plain Copy item is WebKit's tell for a text selection (images and
        // links get Copy Image / Copy Link instead), which is what both of the
        // items below act on.
        guard menu.items.contains(where: { $0.identifier == Self.copyIdentifier }) else { return }

        insertAskEliItem(into: menu)

        // Safari offers its Notes shortcut in this same context.
        guard NotesSharingService.isAvailable else { return }

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

    /// Candoa's own selection action leads the group WebKit puts Search in.
    /// There is no Safari item to inherit placement from, and the question a
    /// person asks about a passage is the same shape as searching for it —
    /// so it sits with Search rather than opening a group of its own.
    private func insertAskEliItem(into menu: NSMenu) {
        let askEli = NSMenuItem(
            title: String(
                localized: "Ask Eli About This",
                comment: "Web context menu: ask the built-in assistant about the selected text."
            ),
            action: #selector(askEliAboutSelection(_:)),
            keyEquivalent: ""
        )
        askEli.target = self

        // WebKit builds this menu itself, out of SwiftUI's reach, so the
        // person's binding is applied here by hand — the item teaches the
        // shortcut the same way a menu-bar item would.
        if let equivalent = ShortcutDefinition.askEliAboutSelection.currentMenuItemKeyEquivalent {
            askEli.keyEquivalent = equivalent.key
            askEli.keyEquivalentModifierMask = equivalent.modifiers
        }

        if let searchIndex = menu.items.firstIndex(where: { $0.identifier == Self.searchWebIdentifier }) {
            menu.insertItem(askEli, at: searchIndex)
        } else {
            menu.insertItem(askEli, at: 0)
        }
    }

    @objc private func askEliAboutSelection(_ sender: NSMenuItem) {
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let selection = result as? String else { return }
            self.coordinator?.askEliAboutSelection(
                selection,
                pageTitle: self.trimmedPageTitle,
                pageURL: self.url
            )
        }
    }

    @objc private func searchWebForSelection(_ sender: NSMenuItem) {
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let selection = result as? String,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.coordinator?.searchInNewTab(selection)
        }
    }

    @objc private func addSelectionToNotes(_ sender: NSMenuItem) {
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            guard let self, let selection = result as? String,
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            // One combined string, not [text, URL]: given a URL item the Notes
            // extension keeps only a link card and drops the text, so fold the
            // source into the note body instead. Lead with the page title so it
            // reads like the card Safari draws, and keep the address on its own
            // line — Notes strips link attributes from shared text, so the bare
            // URL is the only way back to the page.
            var noteText = selection
            if let url = self.url {
                noteText += "\n\n"
                if let pageTitle = self.trimmedPageTitle { noteText += "\(pageTitle)\n" }
                noteText += url.absoluteString
            }
            NotesSharingService.share(items: [noteText])
        }
    }

    /// The page title, when it says something the address does not. Untitled
    /// pages fall back to the address alone rather than an empty heading line.
    private var trimmedPageTitle: String? {
        guard let pageTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pageTitle.isEmpty
        else { return nil }
        return pageTitle
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
