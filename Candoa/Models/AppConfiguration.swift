import CoreGraphics
import Foundation

enum AppConfiguration {
    static let minimumWindowWidth: CGFloat = 980
    static let minimumWindowHeight: CGFloat = 640
    static let browserWindowSceneID = "browser"
    static let privateBrowserWindowSceneID = "browser.private"
    static let acknowledgmentsWindowSceneID = "browser.acknowledgments"
    static let featureFlagsWindowSceneID = "browser.feature-flags"
    static let reportProblemWindowSceneID = "browser.report-problem"
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
    static let newSpace = String(localized: "New Space…")
    static let editSpace = String(localized: "Edit Space…")
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
    static let arrangeTabsBy = String(localized: "Arrange Tabs By")
    static let arrangeTabsByTitle = String(localized: "Title")
    static let arrangeTabsByWebsite = String(localized: "Website")
    static let muteThisTab = String(localized: "Mute This Tab")
    static let unmuteThisTab = String(localized: "Unmute This Tab")
    static let muteOtherTabs = String(localized: "Mute Other Tabs")
    static let getExtensions = String(localized: "Get Extensions…")
    static let acknowledgments = String(localized: "Acknowledgments")
    static let reportAProblem = String(localized: "Report an Issue…")
    static let reportAProblemWindowTitle = String(localized: "Report an Issue")
    static let addToFavorites = String(localized: "Add to Favorites")
    static let removeFromFavorites = String(localized: "Remove from Favorites")
    static let siteInfo = String(localized: "Site Info…")
    static let privacyReport = String(localized: "Privacy Report…")
    static let showReader = String(localized: "Show Reader")
    static let hideReader = String(localized: "Hide Reader")
    static let copyURL = String(localized: "Copy URL")
    static let copyURLAsMarkdown = String(localized: "Copy URL as Markdown")
    static let turnOnDeveloperMode = String(localized: "Turn On Developer Mode")
    static let turnOffDeveloperMode = String(localized: "Turn Off Developer Mode")
    static let openPageWith = String(localized: "Open Page With")
    static let userAgent = String(localized: "User Agent")
    static let showWebInspector = String(localized: "Show Web Inspector")
    static let noInspectablePages = String(localized: "No Inspectable Pages")
    static let developerSettings = String(localized: "Developer Settings…")
    static let featureFlags = String(localized: "Feature Flags…")
    static let featureFlagsWindowTitle = String(localized: "Feature Flags")
    static let closeWebInspector = String(localized: "Close Web Inspector")
    static let connectWebInspector = String(localized: "Connect Web Inspector")
    static let userAgentOther = String(localized: "Other…")
    static let showJavaScriptConsole = String(localized: "Show JavaScript Console")
    static let showPageSource = String(localized: "Show Page Source")
    static let showPageResources = String(localized: "Show Page Resources")
    static let startTimelineRecording = String(localized: "Start Timeline Recording")
    static let stopTimelineRecording = String(localized: "Stop Timeline Recording")
    static let startElementSelection = String(localized: "Start Element Selection")
    static let stopElementSelection = String(localized: "Stop Element Selection")
    static let emptyCaches = String(localized: "Empty Caches")
    static let printPage = String(localized: "Print…")
    static let openFile = String(localized: "Open File…")
    static let saveAs = String(localized: "Save As…")
    static let share = String(localized: "Share…")
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
    // Terminals call this zoom, and the pair reads as one reversible action:
    // the pane fills the surface, then every pane comes back. "Zoom" alone
    // would collide with the page zoom items in the same menu, so the pane
    // is always named.
    static let zoomSplitPane = String(
        localized: "Zoom Pane",
        comment: "Split View: fills the surface with the focused pane. Zooming a pane, not the page — the page-zoom items are separate."
    )
    static let showAllSplitPanes = String(
        localized: "Show All Panes",
        comment: "Split View: brings the other panes back after zooming one."
    )
    static let focusNextSplitPane = String(
        localized: "Focus Next Pane",
        comment: "Split View: moves keyboard focus to the next pane in the split."
    )
    static let focusPreviousSplitPane = String(
        localized: "Focus Previous Pane",
        comment: "Split View: moves keyboard focus to the previous pane in the split."
    )
    static let splitWithTab = String(
        localized: "Split With…",
        comment: "Split View: opens the command bar to pick a tab (or type an address) to place beside the current pane."
    )
    static let unsplitPane = String(
        localized: "Unsplit Pane",
        comment: "Split View: takes the focused pane out of the split; the tab returns to the tab list and keeps the page."
    )
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
    /// One row, no wrap — five recent tabs is a glance, not a grid (Arc shows
    /// five, Firefox six). An odd count also seats the selection dead centre
    /// with equal context either side. Delete backfills from the recency
    /// list, so a long session is pruned from a strip that never grows.
    static let previewLimit = 5

    /// Arc-style hold-to-reveal: a quick Control-Tab switches silently; the
    /// preview overlay only appears if Control is still held after this delay.
    /// Snapshot capture starts on the first press, so this window is also the
    /// time budget for having thumbnails ready before anything is visible.
    static let holdRevealDelay: TimeInterval = 0.18

    static let snapshotWidth: CGFloat = 320

    /// Off-screen preview warm-up: a tab with no thumbnail from any source
    /// is loaded once in a throwaway, unhosted web view of this size, then
    /// captured. A few loads run side by side (each is its own WebContent
    /// process, so this bounds memory), and each gives up after the timeout
    /// so a hung page cannot stall the queue.
    static let warmupViewportSize = CGSize(width: 1024, height: 640)
    static let warmupConcurrency = 3
    static let warmupLoadTimeout: TimeInterval = 15
    /// didFinish precedes first paint of late-arriving content; a short
    /// settle keeps thumbnails from capturing a half-rendered page.
    static let warmupSettleDelay: TimeInterval = 0.6
    /// After the settle, capture waits for the page to go network-quiet:
    /// its resource count must hold still for one quiet period. Single-page
    /// apps (YouTube, mail clients) draw their shell from fetches that start
    /// after didFinish, so a fixed delay alone snapshots their skeleton.
    /// The wait is capped so a page that never stops polling still gets a card.
    static let warmupQuietPeriod: TimeInterval = 0.5
    static let warmupQuietWaitCap: TimeInterval = 4
    /// A breath between one slot's teardown and its next load, so the
    /// WebContent processes do not all spin up in the same instant.
    static let warmupSpacing: TimeInterval = 0.15
    /// The launch pass waits for session restore and first paint to settle
    /// before spending network and CPU on tabs nobody has looked at yet.
    static let warmupLaunchDelay: TimeInterval = 2
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

    /// What the address surfaces show at rest: the domain, nothing else.
    ///
    /// This is Zen's `gZenUIManager.urlbarTrim` under
    /// `zen.urlbar.show-domain-only-in-sidebar` — take the host, drop a
    /// *leading* "www." (only a prefix: "wwwx.example.com" is its own host),
    /// and keep an explicit port, which is part of the origin and the whole
    /// point on a local development page. Arc's sidebar field reads the same.
    ///
    /// Hostless URLs (file:, data:) have no domain to show, so they keep
    /// their full text.
    var displayDomainText: String {
        guard let host = host(percentEncoded: false), !host.isEmpty else {
            return localDevelopmentDisplayText
        }

        var text = host
        if text.hasPrefix("www.") {
            text.removeFirst(4)
        }

        guard let port else { return text }
        return "\(text):\(port)"
    }
}
