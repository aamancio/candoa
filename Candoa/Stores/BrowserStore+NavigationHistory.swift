import Foundation

extension BrowserStore {
    func updateHoveredLink(tabID: UUID, href: String?) {
        // Only the panes the user can point at may drive the pill; a late
        // message from a background tab must not resurrect it.
        guard tabID == activeTabID || activeSplitGroupTabIDs.contains(tabID) else { return }
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

        newTab(url: url)
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
