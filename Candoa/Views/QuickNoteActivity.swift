import SwiftUI

extension View {
    /// Publishes the window's active page as an `NSUserActivity` so Notes can
    /// link a Quick Note back to it.
    ///
    /// Safari's own "Add to Quick Note" context-menu item goes through a
    /// private Notes integration no third-party browser can call.
    /// `NSUserActivity` is the public hook Apple documents for the same
    /// link-back: with a current activity carrying a title and a durable
    /// identifier, Quick Note's Add Link offers the page.
    func quickNoteActivity(for store: BrowserStore) -> some View {
        modifier(QuickNoteActivityModifier(store: store))
    }
}

private struct QuickNoteActivityModifier: ViewModifier {
    @ObservedObject var store: BrowserStore

    func body(content: Content) -> some View {
        let page = linkablePage
        return content.userActivity(
            NSUserActivityTypeBrowsingWeb,
            isActive: page != nil
        ) { activity in
            guard let page else { return }
            activity.title = page.title
            activity.webpageURL = page.url

            // Quick Note needs only the title and the URL. This activity type
            // is also Handoff's, so continuation stays off: broadcasting the
            // open page to the user's other devices is a separate feature,
            // not something to switch on as a side effect of this one.
            activity.isEligibleForHandoff = false
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false
        }
    }

    /// Private windows never publish, and internal pages carry no `url` (the
    /// welcome page and blank tabs), so there is nothing to link back to.
    private var linkablePage: (title: String, url: URL)? {
        guard !store.isPrivate,
              let tab = store.activeTab,
              let url = tab.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return (tab.title, url)
    }
}
