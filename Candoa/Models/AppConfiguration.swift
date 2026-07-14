import CoreGraphics
import Foundation

enum AppConfiguration {
    static let minimumWindowWidth: CGFloat = 980
    static let minimumWindowHeight: CGFloat = 640
    static let windowAutosaveNamePrefix = "Candoa.BrowserWindow"
}

enum BrowserCommandTitles {
    static let newTab = "New Tab"
    static let focusAddressBar = "Focus Address Bar"
    static let commandBar = "Command Bar"
    static let toggleSidebar = "Toggle Sidebar"
    static let toggleAISidebar = "Toggle Ask Sidebar"
    static let reloadTab = "Reload Tab"
    static let back = "Back"
    static let forward = "Forward"
    static let closeCurrentTab = "Close Current Tab"
    static let nextTab = "Next Tab"
    static let previousTab = "Previous Tab"
    static let nextSpace = "Next Space"
    static let previousSpace = "Previous Space"
    static let duplicateTab = "Duplicate Tab"
    static let toggleSplitView = "Toggle Split View"
    static let createSpace = "Create Space"
    static let reopenClosedTab = "Reopen Closed Tab"
    static let pinOrUnpinTab = "Pin or Unpin Tab"
    static let clearUnpinnedTabs = "Clear Unpinned Tabs"
    static let copyURL = "Copy URL"
    static let copyURLAsMarkdown = "Copy URL as Markdown"
    static let findInPage = "Find in Page…"
    static let findNext = "Find Next"
    static let findPrevious = "Find Previous"
    static let zoomIn = "Zoom In"
    static let zoomOut = "Zoom Out"
    static let resetZoom = "Reset Zoom"
    static let addSplitView = "Add Split View"
    static let closeSplitView = "Close Split View"
    static let enableWorkspaceICloudSync = "Enable iCloud Sync for Spaces and Tabs"
    static let disableWorkspaceICloudSync = "Disable iCloud Sync for Spaces and Tabs"
    static let enableHistoryICloudSync = "Enable iCloud Sync for History"
    static let disableHistoryICloudSync = "Disable iCloud Sync for History"
}

enum BrowserDefaults {
    static let newTabTitle = BrowserCommandTitles.newTab
    static let addressPlaceholder = "Search or enter URL"
    static let defaultHomeTitle = "Candoa"
    static let googleHomeURL = URL(string: "https://www.google.com/?hl=en&gl=us")!
    static let googleSearchURL = URL(string: "https://www.google.com/search?hl=en&gl=us")!
}

enum SidebarRevealConfiguration {
    static let revealDistanceFromLeftEdge: CGFloat = 10
    static let suppressionResetDistance: CGFloat = 48
    static let hideDistanceFromLeftEdge: CGFloat = 340
    static let pollingInterval: TimeInterval = 0.12
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
    static let holdRevealDelay: TimeInterval = 0.25
}

extension URL {
    /// Arc's local-development detection: localhost, loopback addresses, and
    /// *.localhost hosts get developer chrome (info icon, full URL, dev bar).
    var isLocalDevelopment: Bool {
        guard let host = host(percentEncoded: false) else { return false }
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost"
            || normalizedHost.hasSuffix(".localhost")
            || normalizedHost == "::1"
            || normalizedHost == "0.0.0.0"
            || normalizedHost.hasPrefix("127.")
    }

    /// Full URL text for developer chrome — scheme, port, and path, with a
    /// bare trailing slash trimmed.
    var localDevelopmentDisplayText: String {
        var text = absoluteString
        if path() == "/", query() == nil, text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }
}
