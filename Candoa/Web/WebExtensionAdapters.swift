import AppKit
import WebKit

/// Presents one browser window (one `BrowserStore`) to web extensions.
///
/// `BrowserTab` is a value type copied in and out of the store's array, and
/// extensions need stable object identity for tabs and windows, so identity
/// lives in these adapter objects instead: one window adapter per store, one
/// tab adapter per tab ID, both owned here for as long as the tab exists.
/// `WebExtensionManager` keeps the adapters in sync with the store and feeds
/// the resulting open/close/activate events to the extension controller.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionWindowAdapter: NSObject {
    private(set) weak var store: BrowserStore?
    private(set) weak var window: NSWindow?

    private(set) var tabAdapters: [UUID: WebExtensionTabAdapter] = [:]
    /// Last tab state the extension controller was told about, for diffing
    /// store changes into open/close/property-change events.
    var knownTabs: [UUID: WebExtensionTabSnapshot] = [:]
    var knownActiveTabID: UUID?

    init(store: BrowserStore, window: NSWindow) {
        self.store = store
        self.window = window
        self.knownActiveTabID = store.activeTabID
        super.init()
    }

    /// Every tab of every Space, in the sidebar's display order: the shared
    /// favorites first, then each Space's pinned, foldered, and regular tabs.
    /// `visibleTabs(in:)` can't be concatenated across Spaces directly — it
    /// leads every Space with the global favorites, which would repeat them.
    var orderedTabs: [BrowserTab] {
        guard let store else { return [] }
        var ordered = store.favoriteTabs
        for space in store.spaces {
            ordered += store.pinnedTabs(in: space.id)
            let spaceFolders = store.folders
                .filter { $0.spaceID == space.id }
                .sorted { $0.sortOrder < $1.sortOrder }
            for folder in spaceFolders {
                ordered += store.tabsInFolder(folder.id)
            }
            ordered += store.regularTabs(in: space.id)
        }
        return ordered
    }

    func adapter(for tabID: UUID) -> WebExtensionTabAdapter {
        if let existing = tabAdapters[tabID] {
            return existing
        }
        let adapter = WebExtensionTabAdapter(tabID: tabID, windowAdapter: self)
        tabAdapters[tabID] = adapter
        return adapter
    }

    func removeAdapter(for tabID: UUID) {
        tabAdapters.removeValue(forKey: tabID)
    }
}

@available(macOS 15.4, *)
extension WebExtensionWindowAdapter: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        orderedTabs.map { adapter(for: $0.id) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let activeTabID = store?.activeTabID else { return nil }
        return adapter(for: activeTabID)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        store?.isPrivate ?? false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .null
    }

    func focus(for context: WKWebExtensionContext) async throws {
        window?.makeKeyAndOrderFront(nil)
    }

    func close(for context: WKWebExtensionContext) async throws {
        window?.performClose(nil)
    }
}

/// The per-tab property state the extension controller was last told about.
/// Kept per window adapter so store updates can be diffed into
/// `didChangeTabProperties` events.
@available(macOS 15.4, *)
struct WebExtensionTabSnapshot {
    let url: URL?
    let title: String
    let isPinned: Bool
    let isLoading: Bool

    init(_ tab: BrowserTab) {
        url = tab.url
        title = tab.title
        isPinned = tab.isPinned
        isLoading = tab.isLoading
    }

    func changedProperties(since previous: WebExtensionTabSnapshot) -> WKWebExtension.TabChangedProperties {
        var changed: WKWebExtension.TabChangedProperties = []
        if url != previous.url { changed.insert(.URL) }
        if title != previous.title { changed.insert(.title) }
        if isPinned != previous.isPinned { changed.insert(.pinned) }
        if isLoading != previous.isLoading { changed.insert(.loading) }
        return changed
    }
}

/// Presents one Candoa tab to web extensions; see `WebExtensionWindowAdapter`.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionTabAdapter: NSObject {
    let tabID: UUID
    private(set) weak var windowAdapter: WebExtensionWindowAdapter?

    init(tabID: UUID, windowAdapter: WebExtensionWindowAdapter) {
        self.tabID = tabID
        self.windowAdapter = windowAdapter
        super.init()
    }

    private var store: BrowserStore? { windowAdapter?.store }
    private var tab: BrowserTab? { store?.tab(tabID) }
    /// Nil while the tab is hibernated or was never displayed — a valid
    /// answer to extensions, which then fall back to the model properties.
    private var liveWebView: WKWebView? { store?.webCoordinator.webViews[tabID] }
}

@available(macOS 15.4, *)
extension WebExtensionTabAdapter: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        windowAdapter?.orderedTabs.firstIndex { $0.id == tabID } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        liveWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.isPinned ?? false
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        store?.activeTabID == tabID
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(liveWebView?.pageZoom ?? 1)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws {
        guard let store else { return }
        store.webCoordinator.setZoom(CGFloat(zoomFactor), tabID: tabID)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let store else { return }
        if liveWebView != nil {
            store.webCoordinator.load(url, in: tabID)
        } else {
            // Hibernated or never displayed: update the model and let the
            // web view pick the URL up when the tab next becomes visible.
            store.setURL(url, title: url.absoluteString, for: tabID)
        }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if fromOrigin {
            liveWebView?.reloadFromOrigin()
        } else {
            liveWebView?.reload()
        }
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        liveWebView?.goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        liveWebView?.goForward()
    }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let store, let tab else { return }
        if tab.spaceID != store.activeSpaceID, !tab.isFavorite {
            store.switchSpace(to: tab.spaceID)
        }
        store.switchTab(to: tabID)
        windowAdapter?.window?.makeKeyAndOrderFront(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        guard selected else { return }
        try await activate(for: context)
    }

    func close(for context: WKWebExtensionContext) async throws {
        store?.closeTab(tabID)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}
