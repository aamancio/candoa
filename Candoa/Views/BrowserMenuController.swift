import AppKit
import SwiftUI

/// Fills the History menu with the pages the person visited.
///
/// This is an `NSMenu` delegate rather than SwiftUI `Commands` because the
/// list has to be built lazily. SwiftUI rebuilds a menu whenever its focused
/// values change, which would mean querying history on every navigation —
/// steady-state work for a menu nobody has opened. `menuNeedsUpdate` runs only
/// when the menu is pulled down.
///
/// Only History is built this way. A menu SwiftUI declares stays SwiftUI's to
/// fill: it rebuilds its own items as the menu bar opens, discarding rows a
/// delegate appended, which left the Spaces menu blank after a Space switch.
@MainActor
final class BrowserMenuController: NSObject, NSMenuDelegate {
    static let shared = BrowserMenuController()

    /// Marks the items this controller owns, so a rebuild replaces only its
    /// own rows and leaves the SwiftUI-declared commands alone.
    private static let dynamicItemTag = 0xCAD0

    private static let recentVisitLimit = 15
    private static let visitsPerDayLimit = 25
    private static let dayLimit = 7
    private static let fetchLimit = 400
    private static let recentlyClosedLimit = 10
    private static let favoriteLimit = 30

    private var stores: [ObjectIdentifier: WeakStore] = [:]
    private var observer: (any NSObjectProtocol)?

    private struct WeakStore {
        weak var window: NSWindow?
        weak var store: BrowserStore?
    }

    /// Every window registers its own store; the menu acts on whichever window
    /// is key, matching the rest of the app's window-scoped commands.
    func register(window: NSWindow, store: BrowserStore) {
        stores[ObjectIdentifier(window)] = WeakStore(window: window, store: store)
        startObservingMenuTracking()
        // The menu has to be claimed before anyone opens it, or the first
        // pull-down shows the static commands with no history under them.
        // SwiftUI may not have built it yet at launch, so this retries.
        attachToHistoryMenu(retries: 10)
    }

    func unregister(window: NSWindow) {
        stores.removeValue(forKey: ObjectIdentifier(window))
    }

    /// The window a store belongs to. Window-scoped actions that a store
    /// starts itself — closing a private window once its last tab is gone —
    /// need their own window, not whichever one happens to be key.
    func window(for store: BrowserStore) -> NSWindow? {
        stores.values.first { $0.store === store }?.window
    }

    /// SwiftUI rebuilds its command menus as focused values change, which drops
    /// any delegate set on them, so the delegate is re-attached each time the
    /// menu bar starts tracking — before the History submenu can open.
    private func startObservingMenuTracking() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToHistoryMenu() }
        }
    }

    private func attachToHistoryMenu(retries: Int = 0) {
        if let menu = historyMenu {
            if menu.delegate !== self {
                menu.delegate = self
            }
            return
        }

        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.attachToHistoryMenu(retries: retries - 1)
        }
    }

    private var historyMenu: NSMenu? {
        let submenus: [NSMenu] = NSApp.mainMenu?.items.compactMap(\.submenu) ?? []
        return submenus.first { menu in
            let titles = menu.items.map(\.title)
            return titles.contains(BrowserCommandTitles.clearHistory)
                && titles.contains(BrowserCommandTitles.reopenClosedTab)
        }
    }

    private var activeStore: BrowserStore? { frontmostStore }

    /// The store behind the frontmost browser window. Settings' "Set to
    /// Current Page" asks while its own panel is key, so after the key
    /// window this walks the window order front-to-back rather than
    /// settling for any visible window.
    var frontmostStore: BrowserStore? {
        if let key = NSApp.keyWindow, let match = stores[ObjectIdentifier(key)]?.store {
            return match
        }
        for window in NSApp.orderedWindows {
            if window.isVisible, let match = stores[ObjectIdentifier(window)]?.store {
                return match
            }
        }
        // A miniaturized window reports isVisible == false and leaves
        // orderedWindows, but its store is still the person's browsing
        // context — better than answering with nothing.
        return stores.values.first(where: { $0.window != nil })?.store
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // SwiftUI sets each command's enabled state itself; leaving AppKit's
        // automatic enabling on lets it override those values with whatever
        // the responder chain reports, which goes stale.
        menu.autoenablesItems = false

        for item in menu.items where item.tag == Self.dynamicItemTag {
            menu.removeItem(item)
        }

        guard let store = activeStore else { return }

        insertRecentlyClosed(from: store, into: menu)
        insertVisits(from: store, into: menu)
        validateStaticCommands(from: store, in: menu)
    }

    /// SwiftUI stops applying its own enabled states to this menu once the
    /// delegate inserts rows into it — its items shift, and commands whose
    /// state depends on a value (rather than on the actions being present at
    /// all) go stale. Since the menu is the delegate's to build, it validates
    /// those commands too, from the same store the rows come from.
    private func validateStaticCommands(from store: BrowserStore, in menu: NSMenu) {
        let states: [String: Bool] = [
            BrowserCommandTitles.back: store.canGoBack,
            BrowserCommandTitles.forward: store.canGoForward,
            BrowserCommandTitles.returnToSearchResults: store.canReturnToSearchResults,
            BrowserCommandTitles.reopenClosedTab: !store.recentlyClosedTabs.isEmpty,
            BrowserCommandTitles.clearHistory: !store.isPrivate
        ]

        for item in menu.items {
            guard let enabled = states[item.title] else { continue }
            item.isEnabled = enabled
        }

        // Enabling a SwiftUI command whose own state says otherwise only
        // changes how it looks — it still swallows the click — so the one
        // command that depends on a changing value is driven from here
        // instead, keeping its title and key equivalent.
        if let item = menu.items.first(where: { $0.title == BrowserCommandTitles.returnToSearchResults }) {
            item.target = self
            item.action = #selector(returnToSearchResults(_:))
            item.isEnabled = store.canReturnToSearchResults
        }
    }

    @objc private func returnToSearchResults(_ sender: NSMenuItem) {
        activeStore?.returnToSearchResults()
    }

    // MARK: - Recently closed

    private func insertRecentlyClosed(from store: BrowserStore, into menu: NSMenu) {
        guard let anchor = menu.items.firstIndex(where: { $0.title == BrowserCommandTitles.reopenClosedTab })
        else { return }

        let closed = store.recentlyClosedTabs.suffix(Self.recentlyClosedLimit).reversed()
        let icons = Self.cachedIcons(from: store)
        let submenu = NSMenu()
        for snapshot in closed {
            let item = NSMenuItem(
                title: Self.title(for: snapshot.url, fallback: snapshot.title),
                action: #selector(reopenClosedTab(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = snapshot.url
            item.image = Self.icon(for: snapshot.url, icons: icons)
            submenu.addItem(item)
        }

        let parent = NSMenuItem(title: BrowserCommandTitles.recentlyClosed, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        parent.isEnabled = !closed.isEmpty
        parent.tag = Self.dynamicItemTag
        menu.insertItem(parent, at: anchor)
    }

    // MARK: - Visited pages

    private func insertVisits(from store: BrowserStore, into menu: NSMenu) {
        guard let anchor = menu.items.firstIndex(where: { $0.title == BrowserCommandTitles.clearHistory })
        else { return }

        let visits = store.historyRepository.recentVisits(
            matching: "",
            in: store.activeSpaceID,
            limit: Self.fetchLimit
        )
        guard !visits.isEmpty else { return }

        let icons = Self.cachedIcons(from: store)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var byDay: [Date: [HistoryVisit]] = [:]
        for visit in visits {
            byDay[calendar.startOfDay(for: visit.visitedAt), default: []].append(visit)
        }

        // Insert upwards from the separator above Clear History, so the rows
        // read newest-first downward once everything is in place.
        var insertion = anchor > 0 && menu.items[anchor - 1].isSeparatorItem ? anchor - 1 : anchor
        var inserted = false

        let earlierDays = byDay.keys.filter { $0 < today }.sorted(by: >).prefix(Self.dayLimit)
        for day in earlierDays.reversed() {
            guard let dayVisits = byDay[day] else { continue }
            let submenu = NSMenu()
            for visit in Self.deduplicated(dayVisits).prefix(Self.visitsPerDayLimit) {
                submenu.addItem(menuItem(for: visit, icons: icons))
            }
            let parent = NSMenuItem(title: Self.dayTitle(for: day), action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.tag = Self.dynamicItemTag
            menu.insertItem(parent, at: insertion)
            inserted = true
        }

        if let todaysVisits = byDay[today], !todaysVisits.isEmpty {
            if inserted {
                let separator = NSMenuItem.separator()
                separator.tag = Self.dynamicItemTag
                menu.insertItem(separator, at: insertion)
            }
            for visit in Self.deduplicated(todaysVisits).prefix(Self.recentVisitLimit).reversed() {
                menu.insertItem(menuItem(for: visit, icons: icons), at: insertion)
            }
            inserted = true
        }

        if inserted {
            let separator = NSMenuItem.separator()
            separator.tag = Self.dynamicItemTag
            menu.insertItem(separator, at: insertion)
        }
    }

    private func menuItem(for visit: HistoryVisit, icons: [String: Data]) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.title(for: visit.url, fallback: visit.title),
            action: #selector(openVisit(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = visit.url
        item.tag = Self.dynamicItemTag
        item.toolTip = visit.url.absoluteString
        item.image = Self.icon(for: visit.url, icons: icons)
        return item
    }

    /// Safari shows a favicon on every row. Fetching one per row would mean
    /// network requests every time the menu opens, so this uses only icons the
    /// app already holds for open tabs and falls back to the same placeholder
    /// symbol the sidebar uses.
    private static func icon(for url: URL, icons: [String: Data]) -> NSImage? {
        let size = NSSize(width: 16, height: 16)

        if let host = url.host(percentEncoded: false),
           let data = icons[host],
           let image = NSImage(data: data) {
            image.size = size
            return image
        }

        let symbol = FaviconService.shared.placeholderSymbol(for: url)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.size = size
        image?.isTemplate = true
        return image
    }

    /// Favicons the open tabs already carry, keyed by host.
    private static func cachedIcons(from store: BrowserStore) -> [String: Data] {
        var icons: [String: Data] = [:]
        for tab in store.tabs {
            guard let host = tab.url?.host(percentEncoded: false), let data = tab.faviconData else { continue }
            icons[host] = data
        }
        return icons
    }

    /// One row per page, keeping the most recent visit to it. Revisits, and
    /// the same article reached through different query strings, would
    /// otherwise fill the menu with the same title over and over.
    private static func deduplicated(_ visits: [HistoryVisit]) -> [HistoryVisit] {
        var seen: Set<String> = []
        return visits.filter { visit in
            var identity = visit.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if identity.isEmpty {
                identity = visit.url.absoluteString
            }
            return seen.insert(identity).inserted
        }
    }

    private static func title(for url: URL?, fallback: String?) -> String {
        let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? (url?.host(percentEncoded: false) ?? url?.absoluteString ?? "") : trimmed
        // Menu rows stay one line; long article titles are truncated the way
        // AppKit truncates its own long menu titles.
        guard title.count > 60 else { return title }
        return title.prefix(59).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func dayTitle(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    // MARK: - Actions

    @objc private func openVisit(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let store = activeStore else { return }
        store.historyDismissRequestID = UUID()
        store.navigateActiveTab(to: url)
    }

    @objc private func reopenClosedTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let store = activeStore else { return }
        store.historyDismissRequestID = UUID()
        store.reopenClosedTab(at: url)
    }
}
