import CoreGraphics
import Foundation

enum AppConfiguration {
    static let minimumWindowWidth: CGFloat = 980
    static let minimumWindowHeight: CGFloat = 640
    static let browserWindowSceneID = "browser"
    static let privateBrowserWindowSceneID = "browser.private"
    static let windowAutosaveNamePrefix = "Candoa.BrowserWindow"
}

enum BrowserCommandTitles {
    static let newTab = String(localized: "New Tab")
    static let focusAddressBar = String(localized: "Focus Address Bar")
    /// Safari's File-menu name for the same command; the palette and the
    /// shortcut editor keep calling it Focus Address Bar, which describes
    /// what it does rather than where it lives.
    static let openLocation = String(localized: "Open Location…")
    static let commandBar = String(localized: "Command Bar")
    static let toggleSidebar = String(localized: "Toggle Sidebar")
    static let toggleAISidebar = String(localized: "Toggle Eli Sidebar")
    static let reloadTab = String(localized: "Reload Page")
    static let reloadTabFromOrigin = String(localized: "Reload Page From Origin")
    static let stopLoading = String(localized: "Stop")
    static let back = String(localized: "Back")
    static let forward = String(localized: "Forward")
    static let closeCurrentTab = String(localized: "Close Current Tab")
    static let nextTab = String(localized: "Next Tab")
    static let previousTab = String(localized: "Previous Tab")
    static let nextSpace = String(localized: "Next Space")
    static let previousSpace = String(localized: "Previous Space")
    static let duplicateTab = String(localized: "Duplicate Tab")
    static let toggleSplitView = String(localized: "Toggle Split View")
    static let createSpace = String(localized: "Create Space")
    static let reopenClosedTab = String(localized: "Reopen Closed Tab")
    /// Safari's History-menu submenu listing the tabs closed this session.
    static let recentlyClosed = String(localized: "Recently Closed")
    static let home = String(localized: "Home")
    static let returnToSearchResults = String(localized: "Return to Search Results")
    static let clearHistory = String(localized: "Clear History…")
    /// The confirming button in the sheet, without the ellipsis.
    static let clearHistoryConfirmation = String(localized: "Clear History")
    static let pinOrUnpinTab = String(localized: "Pin or Unpin Tab")
    static let clearUnpinnedTabs = String(localized: "Clear Unpinned Tabs")
    static let addToFavorites = String(localized: "Add to Favorites")
    static let removeFromFavorites = String(localized: "Remove from Favorites")
    /// Section headers in the Favorites menu.
    static let favoritesGroup = String(localized: "Favorites")
    static let pinnedTabsGroup = String(localized: "Pinned Tabs")
    static let siteInfo = String(localized: "Site Info…")
    static let privacyReport = String(localized: "Privacy Report…")
    static let showReader = String(localized: "Show Reader")
    static let hideReader = String(localized: "Hide Reader")
    static let copyURL = String(localized: "Copy URL")
    static let copyURLAsMarkdown = String(localized: "Copy URL as Markdown")
    static let turnOnDeveloperMode = String(localized: "Turn On Developer Mode")
    static let turnOffDeveloperMode = String(localized: "Turn Off Developer Mode")
    static let printPage = String(localized: "Print…")
    static let openFile = String(localized: "Open File…")
    static let saveAs = String(localized: "Save As…")
    static let exportAsPDF = String(localized: "Export as PDF…")
    /// Titles of the two Safari-style submenus that keep the Edit and View
    /// menus short.
    static let findMenu = String(localized: "Find")
    static let splitViewMenu = String(localized: "Split View")
    static let findInPage = String(localized: "Find in Page…")
    static let findNext = String(localized: "Find Next")
    static let findPrevious = String(localized: "Find Previous")
    static let zoomIn = String(localized: "Zoom In")
    static let zoomOut = String(localized: "Zoom Out")
    static let resetZoom = String(localized: "Reset Zoom")
    static let addSplitView = String(localized: "Add Split View")
    static let closeSplitView = String(localized: "Close Split View")
    // "Horizontal"/"Vertical" read backwards to half of everyone: the panes
    // sit horizontally, but the divider between them is vertical, and
    // terminals name the split after the divider. Name the arrangement
    // instead -- neither word can be read the other way round.
    static let splitLayoutHorizontal = String(localized: "Side by Side")
    static let splitLayoutVertical = String(localized: "Stacked")
}

enum BrowserDefaults {
    static let newTabTitle = BrowserCommandTitles.newTab
    static let addressPlaceholder = String(localized: "Search or enter URL")
    static let defaultHomeTitle = "Candoa"
    static let googleHomeURL = URL(string: "https://www.google.com/")!
    static let googleSearchURL = URL(string: "https://www.google.com/search")!
}

enum SidebarRevealConfiguration {
    static let revealDistanceFromLeftEdge: CGFloat = 10
    static let suppressionResetDistance: CGFloat = 48
    static let hideDistanceFromLeftEdge: CGFloat = 340
}

enum TabHibernationConfiguration {
    /// Background tabs untouched for this long are hibernated: their
    /// interaction state is captured and the WKWebView (and its WebContent
    /// process) is torn down until the tab is activated again.
    static let idleInterval: TimeInterval = 15 * 60

    /// How often the coordinator scans for hibernation candidates.
    static let scanInterval: TimeInterval = 60

    /// Wake-up snapshots are captured at most this wide (points); they only
    /// bridge the moment between activating a hibernated tab and first paint.
    static let snapshotMaxWidth: CGFloat = 1024

    /// Upper bound on retained wake-up snapshots, preferring hibernated tabs.
    static let snapshotCacheLimit = 16
}

enum WebInspectorConfiguration {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = UserDefaults.standard.bool(forKey: "CandoaEnableWebInspector")
    #endif
}

enum TabSwitcherConfiguration {
    static let previewLimit = 10

    /// Arc-style hold-to-reveal: a quick Control-Tab switches silently; the
    /// preview overlay only appears if Control is still held after this delay.
    /// Snapshot capture starts on the first press, so this window is also the
    /// time budget for having thumbnails ready before anything is visible.
    static let holdRevealDelay: TimeInterval = 0.18

    static let snapshotWidth: CGFloat = 320
}

/// Per-site Developer Mode mirrors Arc's behavior: local servers opt in by
/// default, while any other host can be explicitly enabled from site controls
/// or the Command Bar. The value is a small host → override map, so it neither
/// observes pages nor adds any work to the WebContent process.
enum DeveloperModeConfiguration {
    static let storageKey = "Candoa.DeveloperModeSiteOverrides"

    static func isEnabled(for url: URL, storedOverrides: String? = nil) -> Bool {
        guard let host = normalizedHost(for: url) else { return false }

        if let override = overrides(from: storedOverrides)[host] {
            return override
        }

        return url.isLocalDevelopment
    }

    static func setEnabled(_ isEnabled: Bool, for url: URL) {
        guard let host = normalizedHost(for: url) else { return }

        var overrides = overrides(from: nil)
        overrides[host] = isEnabled
        UserDefaults.standard.set(encoded(overrides), forKey: storageKey)
    }

    static func displayHost(for url: URL) -> String? {
        normalizedHost(for: url)
    }

    private static func normalizedHost(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    private static func overrides(from storedValue: String?) -> [String: Bool] {
        let value = storedValue ?? UserDefaults.standard.string(forKey: storageKey) ?? ""
        guard
            let data = value.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return [:]
        }

        return decoded
    }

    private static func encoded(_ overrides: [String: Bool]) -> String {
        guard
            let data = try? JSONEncoder().encode(overrides),
            let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return value
    }
}

extension URL {
    /// Arc's local-development detection: localhost, loopback addresses, and
    /// *.localhost hosts get developer controls (info icon, full URL, dev bar).
    var isLocalDevelopment: Bool {
        guard let host = host(percentEncoded: false) else { return false }
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost"
            || normalizedHost.hasSuffix(".localhost")
            || normalizedHost == "::1"
            || normalizedHost == "0.0.0.0"
            || normalizedHost.hasPrefix("127.")
    }

    /// Full URL text for developer controls — scheme, port, and path, with a
    /// bare trailing slash trimmed.
    var localDevelopmentDisplayText: String {
        var text = absoluteString
        if path() == "/", query() == nil, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
