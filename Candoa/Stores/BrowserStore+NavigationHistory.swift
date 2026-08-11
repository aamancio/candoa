import Foundation
import Network
import WebKit

extension BrowserStore {
    // MARK: - Navigation & WebContent Recovery

    func reportLoadFailure(tabID: UUID, error: NSError, failedURL: URL?) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        guard let failure = TabLoadFailure.make(from: error, failedURL: failedURL) else { return }
        tabLoadFailures[tabID] = failure
        syncOfflineRecoveryMonitor()
    }

    func reportWebContentTermination(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tabLoadFailures[tabID] = TabLoadFailure(
            kind: .processTerminated,
            failedURL: tab.url,
            message: ""
        )
    }

    func clearLoadFailure(tabID: UUID) {
        guard tabLoadFailures[tabID] != nil else { return }
        tabLoadFailures[tabID] = nil
        syncOfflineRecoveryMonitor()
    }

    func retryLoadFailure(tabID: UUID) {
        guard let failure = tabLoadFailures[tabID] else { return }
        switch failure.kind {
        case .processTerminated:
            webCoordinator.reload(tabID: tabID)
        default:
            // A failed provisional navigation leaves the web view on its old
            // URL (or none), so reload would revisit the wrong page — load
            // the destination that actually failed.
            if let url = failure.failedURL ?? tabs.first(where: { $0.id == tabID })?.url {
                webCoordinator.load(url, in: tabID)
            } else {
                webCoordinator.reload(tabID: tabID)
            }
        }
    }

    /// The path monitor is strictly scoped to visible offline failures:
    /// created when the first appears, cancelled when the last clears.
    /// Reconnection retries the affected tabs so browsing restores without
    /// the user touching anything.
    private func syncOfflineRecoveryMonitor() {
        let hasOfflineFailure = tabLoadFailures.values.contains { $0.kind == .offline }

        if hasOfflineFailure, offlineRecoveryMonitor == nil {
            offlineMonitorSawUnsatisfiedPath = false
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let isSatisfied = path.status == .satisfied
                Task { @MainActor [weak self] in
                    self?.handleNetworkPathUpdate(isSatisfied: isSatisfied)
                }
            }
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            offlineRecoveryMonitor = monitor
        } else if !hasOfflineFailure, let monitor = offlineRecoveryMonitor {
            monitor.cancel()
            offlineRecoveryMonitor = nil
        }
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool) {
        guard offlineRecoveryMonitor != nil else { return }
        guard isSatisfied else {
            offlineMonitorSawUnsatisfiedPath = true
            return
        }
        // The monitor's very first callback reports the current path; only a
        // genuine unsatisfied → satisfied transition should trigger retries,
        // or a failure would re-fire the moment its monitor starts.
        guard offlineMonitorSawUnsatisfiedPath else { return }
        offlineMonitorSawUnsatisfiedPath = false

        for (tabID, failure) in tabLoadFailures where failure.kind == .offline {
            retryLoadFailure(tabID: tabID)
        }
    }

    func updateHoveredLink(tabID: UUID, href: String?) {
        // Only the panes the user can point at may drive the pill; a late
        // message from a background tab must not resurrect it.
        guard tabID == activeTabID || displayedSplitTabIDs.contains(tabID) else { return }
        guard hoveredLinkHref != href else { return }
        hoveredLinkHref = href
    }

    func openExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        dismissCommandPalette()
        _ = newTab(url: url)
    }

    func navigateActiveTab(to rawInput: String) {
        guard let url = navigationService.destinationURL(
            for: rawInput,
            defaultSearchProviderID: defaultSearchProviderID
        ) else { return }
        navigateActiveTab(to: url)
    }

    func navigateActiveTab(to url: URL) {
        // Empty spaces have no active tab; navigating from the address
        // dialog should open one rather than dropping the input.
        guard let activeTab else {
            _ = newTab(url: url)
            return
        }

        // Favorites and pinned tabs are saved destinations. Navigating the
        // address bar to another site should preserve that destination and
        // create a regular tab for the new page, rather than leaving the
        // sidebar with no visible tab for the page the user just opened.
        if shouldOpenNewTab(from: activeTab, to: url) {
            _ = newTab(url: url)
            return
        }

        setURL(url, title: title(for: url), for: activeTab.id)
        webCoordinator.load(url, in: activeTab.id)
    }

    func navigateNewTab(to rawInput: String) {
        guard let url = navigationService.destinationURL(
            for: rawInput,
            defaultSearchProviderID: defaultSearchProviderID
        ) else { return }
        navigateNewTab(to: url)
    }

    func navigateNewTab(to url: URL) {
        // A URL-less active tab and the Welcome page are transient starting
        // surfaces. Fill them instead of leaving a placeholder beside the
        // real destination in the sidebar.
        if let activeTab, activeTab.url == nil || activeTab.isWelcomePage {
            navigateActiveTab(to: url)
            return
        }

        _ = newTab(url: url)
    }

    /// Safari's Home: the address set in Settings, in the current tab.
    func goHome() {
        guard let url = HomepagePreference.url else { return }
        navigateActiveTab(to: url)
    }

    /// Safari's Return to Search Results: jumps back to the search page this
    /// tab came from, however many links deep you have wandered since.
    func returnToSearchResults() {
        guard let activeTabID, let item = lastSearchResultsItem(in: activeTabID) else { return }
        webCoordinator.go(to: item, in: activeTabID)
    }

    var canReturnToSearchResults: Bool {
        guard let activeTabID else { return false }
        return lastSearchResultsItem(in: activeTabID) != nil
    }

    private func lastSearchResultsItem(in tabID: UUID) -> WKBackForwardListItem? {
        webCoordinator.lastSearchResultsItem(tabID: tabID) { [navigationService] url in
            navigationService.searchQuery(from: url) != nil
        }
    }

    func goBack() {
        guard let activeTabID else { return }
        webCoordinator.goBack(tabID: activeTabID)
    }

    func goForward() {
        guard let activeTabID else { return }
        webCoordinator.goForward(tabID: activeTabID)
    }

    func reloadActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.reload(tabID: activeTabID)
    }

    func reloadActiveTabFromOrigin() {
        guard let activeTabID else { return }
        webCoordinator.reloadFromOrigin(tabID: activeTabID)
    }

    /// Printable means real page content in the active pane: a loaded web
    /// view showing an actual URL. In split view the active tab is the
    /// focused pane, so that pane is what prints.
    var canPrintActiveTab: Bool {
        guard let activeTab else { return false }
        return activeTab.url != nil
            && !activeTab.isWelcomePage
            && webCoordinator.hasLoadedWebView(for: activeTab.id)
    }

    func printActiveTab() {
        guard canPrintActiveTab, let activeTabID else { return }
        webCoordinator.printPage(for: activeTabID)
    }

    func stopLoadingActiveTab() {
        guard let activeTabID else { return }
        webCoordinator.stopLoading(tabID: activeTabID)
        setLoading(false, for: activeTabID)
    }

    /// Stops only when a load is actually in progress, reporting whether the
    /// shortcut was handled — an idle Command-. must stay available to
    /// dialogs as the system cancel key.
    func stopLoadingActiveTabIfLoading() -> Bool {
        guard let activeTab, activeTab.isLoading else { return false }
        stopLoadingActiveTab()
        return true
    }

    func updateTabFromWebView(
        tabID: UUID,
        title: String?,
        url: URL?,
        isLoading: Bool,
        loadingProgress: Double,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // The internal home page is loaded via loadHTMLString and WebKit
        // reports it as about:blank; keep the tab URL-less instead of
        // surfacing the placeholder in the tab row and address bar.
        let isInternalHomePage = Self.isInternalBlankPlaceholderURL(url)
        let reportedURL = isInternalHomePage ? nil : url

        if isInternalHomePage {
            tabs[index].title = BrowserDefaults.newTabTitle
        } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabs[index].title = title
        } else if let reportedURL {
            tabs[index].title = self.title(for: reportedURL)
        }

        tabs[index].url = reportedURL
        tabs[index].faviconSymbol = faviconService.placeholderSymbol(for: reportedURL)
        tabs[index].isLoading = isLoading
        tabs[index].loadingProgress = loadingProgress
        updateFavoriteSnapshotIfStillOnSavedURL(at: index)

        if activeTabID == tabID {
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
        }
    }

    func updateFavicon(tabID: UUID, data: Data?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), let data else { return }
        tabs[index].faviconData = data
        if tabs[index].isFavorite && favoriteSnapshotMatchesLiveURL(tabs[index]) {
            tabs[index].favoriteFaviconData = data
        }
    }

    func recordHistoryVisit(tabID: UUID, title: String?, url: URL?) {
        guard
            let index = tabs.firstIndex(where: { $0.id == tabID }),
            let url,
            !Self.isInternalBlankPlaceholderURL(url)
        else {
            return
        }

        tabs[index].lastAccessedAt = Date()
        let tab = tabs[index]

        let resolvedTitle: String
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedTitle = title
        } else {
            resolvedTitle = self.title(for: url)
        }

        historyRepository.record(
            HistoryVisit(
                id: UUID(),
                title: resolvedTitle,
                url: url,
                tabID: tabID,
                spaceID: tab.spaceID,
                visitedAt: Date()
            )
        )
    }

    func recentHistory(matching query: String = "", limit: Int = 8) -> [HistoryVisit] {
        historyRepository.recentVisits(matching: query, in: activeSpaceID, limit: limit)
    }

    func setLoading(_ isLoading: Bool, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].isLoading = isLoading
        updateNavigationState()
    }

    func setURL(_ url: URL, title: String, for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].url = url
        tabs[index].title = title
        tabs[index].faviconSymbol = faviconService.placeholderSymbol(for: url)
        tabs[index].faviconData = nil
        tabs[index].isLoading = true
        tabs[index].loadingProgress = 0.05
        tabs[index].lastAccessedAt = Date()
    }

    func shouldOpenNewTab(from tab: BrowserTab, to destination: URL) -> Bool {
        guard tab.isFavorite || tab.isPinned, let currentURL = tab.url else {
            return false
        }

        // Keep normal in-site navigation in the saved tab. A different host
        // is a new browsing task and belongs in an ordinary tab.
        return differentHosts(currentURL, destination)
    }

    func differentHosts(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.host(percentEncoded: false)?.lowercased()
            != rhs.host(percentEncoded: false)?.lowercased()
    }

    func captureFavoriteSnapshot(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].favoriteTitle = tabs[index].title
        tabs[index].favoriteURL = tabs[index].url
        tabs[index].favoriteFaviconSymbol = tabs[index].faviconSymbol
        tabs[index].favoriteFaviconData = tabs[index].faviconData
    }

    func clearFavoriteSnapshot(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].favoriteTitle = nil
        tabs[index].favoriteURL = nil
        tabs[index].favoriteFaviconSymbol = nil
        tabs[index].favoriteFaviconData = nil
    }

    func updateFavoriteSnapshotIfStillOnSavedURL(at index: Int) {
        guard tabs.indices.contains(index), tabs[index].isFavorite else { return }
        if tabs[index].favoriteURL == nil {
            captureFavoriteSnapshot(at: index)
            return
        }

        guard favoriteSnapshotMatchesLiveURL(tabs[index]) else { return }
        tabs[index].favoriteTitle = tabs[index].title
        tabs[index].favoriteFaviconSymbol = tabs[index].faviconSymbol
        if let faviconData = tabs[index].faviconData {
            tabs[index].favoriteFaviconData = faviconData
        }
    }

    func favoriteSnapshotMatchesLiveURL(_ tab: BrowserTab) -> Bool {
        guard let favoriteURL = tab.favoriteURL else { return true }
        return tab.url == favoriteURL
    }

    func title(for url: URL?) -> String {
        guard let url else { return BrowserDefaults.newTabTitle }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    func updateNavigationState() {
        guard let activeTabID else {
            canGoBack = false
            canGoForward = false
            return
        }

        let state = webCoordinator.navigationState(for: activeTabID)
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
    }

    static func isInternalBlankPlaceholderURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.absoluteString == "about:blank"
    }
}
