import Foundation
import WebKit

extension BrowserStore {
    // MARK: - Develop Menu

    /// Develop tools need real page content in the active pane: a loaded
    /// web view showing an actual URL, mirroring `canPrintActiveTab`.
    var canUseDevelopTools: Bool {
        guard let activeTab else { return false }
        return activeTab.url != nil
            && webCoordinator.hasLoadedWebView(for: activeTab.id)
    }

    func showWebInspector() {
        guard let activeTabID else { return }
        webCoordinator.showWebInspector(for: activeTabID)
    }

    func showJavaScriptConsole() {
        guard let activeTabID else { return }
        webCoordinator.showJavaScriptConsole(for: activeTabID)
    }

    func showPageSource() {
        guard let activeTabID else { return }
        webCoordinator.showPageSource(for: activeTabID)
    }

    func showPageResources() {
        guard let activeTabID else { return }
        webCoordinator.showPageResources(for: activeTabID)
    }

    var isRecordingTimeline: Bool {
        guard let activeTabID else { return false }
        return webCoordinator.isRecordingTimeline(for: activeTabID)
    }

    func toggleTimelineRecording() {
        guard let activeTabID else { return }
        webCoordinator.toggleTimelineRecording(for: activeTabID)
        // The menu item's title flips with the recording state, which lives
        // in the coordinator; nudge observers so the menu re-renders.
        objectWillChange.send()
    }

    var isSelectingElement: Bool {
        guard let activeTabID else { return false }
        return webCoordinator.isSelectingElement(for: activeTabID)
    }

    func toggleElementSelection() {
        guard let activeTabID else { return }
        webCoordinator.toggleElementSelection(for: activeTabID)
        objectWillChange.send()
    }

    // MARK: - User Agent

    /// The web view backing the active tab, if it has been created.
    private var activeWebView: WKWebView? {
        guard let activeTabID else { return nil }
        return webCoordinator.webViews[activeTabID]
    }

    var activeUserAgentPreset: UserAgentPreset {
        UserAgentConfiguration.preset(matching: activeWebView?.customUserAgent)
    }

    func setUserAgentPreset(_ preset: UserAgentPreset) {
        guard let webView = activeWebView else { return }
        webView.customUserAgent = preset.userAgent
        reloadActiveTab()
        objectWillChange.send()
    }

    // MARK: - Caches

    /// Removes only the active Space's caches, leaving cookies, storage and
    /// everything else in place — Safari's Develop ▸ Empty Caches.
    func emptyCaches() {
        // Private windows browse against non-persistent stores owned by
        // their own coordinators; like BrowsingDataService, nothing
        // reachable from here can touch private-browsing data.
        guard !isPrivate, let url = activeTab?.url else { return }

        // Resolve through the shared instance: a second
        // WKWebsiteDataStore(forIdentifier:) for a live identifier tears
        // down its network session on dealloc.
        let dataStore = WebViewCoordinator.sharedDataStore(
            forIdentifier: dataStoreID(for: activeSpaceID)
        )
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache
        ]
        Task { [weak self] in
            await dataStore.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast)
            self?.presentCopiedURLToast(title: String(localized: "Caches Emptied"), url: url)
        }
    }

    // MARK: - External Browsers

    func openActivePage(with browser: ExternalBrowserService.Browser) {
        guard let url = activeTab?.url else { return }
        ExternalBrowserService.open(url, with: browser)
    }
}
