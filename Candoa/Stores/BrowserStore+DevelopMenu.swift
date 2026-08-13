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

    var isWebInspectorVisible: Bool {
        guard let activeTabID else { return false }
        return webCoordinator.isWebInspectorVisible(for: activeTabID)
    }

    func toggleWebInspector() {
        guard let activeTabID else { return }
        webCoordinator.toggleWebInspector(for: activeTabID)
        objectWillChange.send()
    }

    func connectWebInspector() {
        guard let activeTabID else { return }
        webCoordinator.connectWebInspector(for: activeTabID)
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

    /// nil while a custom (Other…) user agent is set, so no preset is checked.
    var activeUserAgentPreset: UserAgentPreset? {
        UserAgentConfiguration.preset(matching: activeWebView?.customUserAgent)
    }

    var isCustomUserAgentActive: Bool {
        activeUserAgentPreset == nil && activeWebView?.customUserAgent?.isEmpty == false
    }

    func setUserAgentPreset(_ preset: UserAgentPreset) {
        guard let webView = activeWebView else { return }
        webView.customUserAgent = preset.userAgent
        reloadActiveTab()
        objectWillChange.send()
    }

    /// Safari's User Agent ▸ Other…: a sheet asking for a free-form string.
    func promptForCustomUserAgent() {
        guard let webView = activeWebView else { return }
        if let custom = webView.customUserAgent, !custom.isEmpty {
            presentCustomUserAgentPrompt(prefill: custom)
            return
        }
        // No override yet: prefill with the page's live default, like Safari.
        Task { [weak self] in
            let liveAgent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
            self?.presentCustomUserAgentPrompt(prefill: liveAgent ?? "")
        }
    }

    private func presentCustomUserAgentPrompt(prefill: String) {
        guard let webView = activeWebView else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Custom User Agent")
        alert.informativeText = String(localized: "Enter a complete user agent string for the current page.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = prefill
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            webView.customUserAgent = value.isEmpty ? nil : value
            self.reloadActiveTab()
            self.objectWillChange.send()
        }

        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    // MARK: - Inspectable Pages

    /// One row in Develop's device submenu, Safari's per-page inspection
    /// targets scoped to Candoa's own pages.
    struct InspectablePage: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    var inspectablePages: [InspectablePage] {
        tabs.compactMap { tab in
            guard let url = tab.url, webCoordinator.hasLoadedWebView(for: tab.id) else {
                return nil
            }
            // Safari labels targets host-first ("en.wikipedia.org — Rose_…"),
            // falling back to the tab title for hostless pages.
            var title = url.host() ?? tab.title
            let component = url.lastPathComponent
            if component.count > 1 {
                title += " — " + component
            }
            return InspectablePage(id: tab.id, title: title)
        }
    }

    /// Jumps to the page the way Safari's device submenu does, then opens
    /// its inspector once the tab (and possibly Space) switch has committed.
    func inspectPage(_ tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        switchTab(to: tabID)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                self?.webCoordinator.showWebInspector(for: tabID)
            }
        }
        CATransaction.commit()
    }

    // MARK: - Service Workers

    /// Repopulates Develop ▸ Service Workers from the active window's data
    /// store. Fired as menu-bar tracking begins so the submenu reflects the
    /// registrations of the moment, the way Safari fills it on open.
    func refreshServiceWorkerRegistrations() {
        // Private windows browse against their own non-persistent store, so
        // resolve through the live web view first; the Space's shared store
        // covers windows that have no page loaded yet.
        let dataStore = activeWebView?.configuration.websiteDataStore
            ?? WebViewCoordinator.sharedDataStore(forIdentifier: dataStoreID(for: activeSpaceID))
        Task { [weak self] in
            let records = await dataStore.dataRecords(
                ofTypes: [WKWebsiteDataTypeServiceWorkerRegistrations]
            )
            let domains = Array(Set(records.map(\.displayName))).sorted()
            guard let self, self.serviceWorkerDomains != domains else { return }
            self.serviceWorkerDomains = domains
        }
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
