import AppKit
import Foundation
import WebKit

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    struct PendingWebAppPrompt {
        let providerID: String
        let query: String
    }

    static let pageZoomLevels: [CGFloat] = [0.5, 0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let browserAgentContentWorld = WKContentWorld.world(name: "CandoaBrowserAgent")
    /// Ends at `Safari/605.1.15`, with nothing of ours appended. Sites match
    /// the user agent against known-browser strings, and an unrecognized
    /// trailing token reads as a scripted client — Google's unusual-traffic
    /// interstitial being the one that bit us. Identify Candoa on our own
    /// requests with a header instead; browsing traffic stays Safari-shaped.
    static let browserUserAgentApplicationName: String = {
        let safariVersion = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        return "Version/\(safariVersion ?? fallbackSafariVersion) Safari/605.1.15"
    }()

    static var fallbackSafariVersion: String {
        let macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safariMajorVersion = macOSMajorVersion >= 26 ? macOSMajorVersion : macOSMajorVersion + 3
        return "\(safariMajorVersion).0"
    }

    /// Private windows browse against a single non-persistent data store:
    /// cookies, caches, and site state live only in memory and vanish when
    /// the coordinator (and its window) goes away. WebKit hands popups the
    /// opener's configuration, so `target=_blank` pages inherit it for free.
    let isPrivate: Bool
    private let privateDataStore: WKWebsiteDataStore?

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        self.privateDataStore = isPrivate ? .nonPersistent() : nil
        super.init()
    }

    deinit {
        stopMemoryPressureMonitoring()
    }

    /// Owns a block-based NotificationCenter registration and unregisters it
    /// when released, so a MainActor class can drop the observation from its
    /// nonisolated deinit via plain ARC.
    private final class NotificationToken {
        private let token: any NSObjectProtocol

        init(_ token: any NSObjectProtocol) {
            self.token = token
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }

    weak var store: BrowserStore?
    var webViews: [UUID: WKWebView] = [:]
    var tabIDsByWebView = NSMapTable<WKWebView, NSString>.weakToStrongObjects()
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    var pendingWebAppPrompts: [UUID: PendingWebAppPrompt] = [:]
    var popupTabIDsAwaitingFirstLoad = Set<UUID>()
    var activeDownloads = Set<WKDownload>()
    var downloadDestinations: [WKDownload: URL] = [:]
    /// Tabs whose last navigation converted to a download: the model may
    /// keep showing the download URL (provisional-URL updates race any
    /// cleanup), but re-requesting it via ensureLoaded would start the
    /// download again on every SwiftUI pass. Cleared when a real page
    /// commits in the tab.
    var downloadConvertedTabIDs: Set<UUID> = []
    /// Per-tab destination whose provisional navigation failed. A provisional
    /// failure never commits, so the web view keeps its previous URL and the
    /// mismatch ensureLoaded tests against stays true forever: re-requesting
    /// the destination republishes the failure, which drives the next SwiftUI
    /// pass, which re-requests it again — an unbounded navigate/render loop
    /// (a mistyped host spun at ~20 loads a second). Cleared when a page
    /// commits in the tab and by any explicit load, so retry still works.
    var failedProvisionalURLs: [UUID: URL] = [:]
    var hostedActiveTabID: UUID?
    /// Last docked-inspector placement published to the UI-testing state, so
    /// WebKit's own re-splits (which no store change accompanies) refresh it
    /// exactly once each.
    var lastReportedInspectorPlacement: String?
    var miniPlayerHostedTabID: UUID?
    /// Summon glide in flight for the hosted tab: its page is still at full
    /// layout, scaled into the player by the host's bounds (see
    /// `hostMiniPlayerWebView`), until the glide lands and the freeze frame
    /// for the strip-down is in.
    var miniPlayerSummon: MiniPlayerSummonHandoff?
    var contentRuleList: WKContentRuleList?
    /// Whether the compiled rule list is currently attached to web views —
    /// diverges from the preference only until the observer reconciles.
    var appliedTrackingProtection = false
    var hibernatedInteractionStates: [UUID: Data] = [:]
    var wakeSnapshots: [UUID: NSImage] = [:]
    var restoringTabIDs = Set<UUID>()
    var restoreOverlays: [UUID: NSImageView] = [:]
    /// Off-screen preview warm-up (WebViewCoordinator+PreviewWarmup): tabs
    /// waiting for a throwaway load, the one load in flight, and every tab
    /// tried this run so a page that fails to render is not retried on each
    /// switcher open.
    var previewWarmupQueue: [BrowserTab] = []
    var previewWarmupJobs: [UUID: PreviewWarmupJob] = [:]
    var previewWarmupAttemptedTabIDs = Set<UUID>()
    /// A visible tab's first WebContent crash reloads silently; a repeat
    /// within this window surfaces recovery UI instead of crash-looping.
    var webContentTerminationDates: [UUID: Date] = [:]
    /// Tabs whose finished page has already answered the reader-availability
    /// probe, so switching back to a tab never re-runs it.
    var readerProbedTabIDs = Set<UUID>()
    /// Memory-pressure events are the only thing that hibernates a tab
    /// (WebViewCoordinator+Hibernation). nonisolated(unsafe): cancelled from
    /// the nonisolated deinit, where a main-actor property is unreachable.
    nonisolated(unsafe) var memoryPressureSource: DispatchSourceMemoryPressure?
    nonisolated(unsafe) var debugMemoryPressureObserver: (any NSObjectProtocol)?
    private var userDefaultsObserver: NotificationToken?
    var websiteAppearance = WebsiteAppearance.automatic
    var systemUsesDarkAppearance = false
    var pendingAppearanceNavigationTokens: [UUID: UUID] = [:]
    private lazy var browserAgentDriver = BrowserAgentDriver(
        contentWorld: Self.browserAgentContentWorld
    )

    func attach(store: BrowserStore) {
        self.store = store

        Task { [weak self] in
            await self?.applyContentRuleList()
        }

        // The strict-tracking-protection toggle takes effect on live web
        // views (their next load), not just newly created ones. Defaults can
        // change on any thread (CloudKit writes some at launch), so the
        // observation must marshal onto the main queue — a selector-based
        // observer runs on the posting thread and trips this class's
        // MainActor isolation assertion.
        userDefaultsObserver = NotificationToken(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.userDefaultsDidChange()
                }
            }
        )

        // Launch pass for switcher previews, once restore and first paint
        // have had time to settle (WebViewCoordinator+PreviewWarmup).
        DispatchQueue.main.asyncAfter(deadline: .now() + TabSwitcherConfiguration.warmupLaunchDelay) { [weak self] in
            self?.store?.warmUpTabSwitcherPreviewsIfNeeded()
        }

        startMemoryPressureMonitoring()
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let existingWebView = webViews[tab.id] {
            return existingWebView
        }

        let webView = makeWebView(for: tab)
        // The real page is about to render; a pending throwaway load for the
        // same tab would only duplicate the network cost.
        cancelPreviewWarmup(for: tab.id)

        if let interactionState = hibernatedInteractionStates.removeValue(forKey: tab.id) {
            // Waking a hibernated tab: restores the back/forward list, scroll
            // position, and current page without a cold load.
            restoringTabIDs.insert(tab.id)
            webView.interactionState = interactionState
        } else if let url = tab.url {
            load(url, in: tab.id)
        }

        return webView
    }

    /// One live store object per identifier, for the app's lifetime.
    /// WKWebsiteDataStore(forIdentifier:) instances are NOT uniqued by
    /// WebKit: each is a distinct session owner, and when any of them
    /// deallocates WebKit tears down the identifier's network session and
    /// kills the WebContent processes of every page riding it. Handing
    /// each web view its own instance meant a sibling web view's teardown
    /// (hibernation, tab close) could reap a live tab's process — most
    /// visibly killing cross-origin link navigations moments after their
    /// process swap committed, which read as "clicking does nothing".
    private static var dataStoresByIdentifier: [UUID: WKWebsiteDataStore] = [:]

    static func sharedDataStore(forIdentifier identifier: UUID) -> WKWebsiteDataStore {
        if let existing = dataStoresByIdentifier[identifier] {
            return existing
        }
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        dataStoresByIdentifier[identifier] = dataStore
        return dataStore
    }

    func makeWebView(for tab: BrowserTab) -> WKWebView {
        let dataStore: WKWebsiteDataStore
        if let privateDataStore {
            dataStore = privateDataStore
        } else {
            let dataStoreID = store?.dataStoreID(for: tab.spaceID) ?? tab.spaceID
            dataStore = Self.sharedDataStore(forIdentifier: dataStoreID)
        }

        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        // WKWebView's embedded user agent omits Safari's compatibility tokens,
        // causing sites such as Google to serve a reduced fallback experience.
        configuration.applicationNameForUserAgent = Self.browserUserAgentApplicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.websiteDataStore = dataStore
        if #available(macOS 15.1, *) {
            configuration.writingToolsBehavior = .complete
        }
        // Web extensions ride the shared controller. Private windows carry it
        // too, but only extensions the person explicitly granted "Allow in
        // Private Browsing" (hasAccessToPrivateData) ever see their pages.
        if #available(macOS 15.4, *) {
            configuration.webExtensionController = WebExtensionManager.shared.controller
        }

        // "Inspect Element" in the web context menu needs WebKit's developer
        // extras; isInspectable alone only permits external inspector attach.
        // KVC resolves the key to the private _setDeveloperExtrasEnabled:, so
        // probe for it first and degrade to a missing menu item, not a crash.
        if WebInspectorConfiguration.isEnabled,
           configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }

        // Feature Flags overrides reach only web views created after a change.
        WebKitFeatureFlags.apply(to: configuration.preferences)

        let webView = BrowserWebView(frame: .zero, configuration: configuration)
        register(webView, for: tab.id)
        return webView
    }

    // MARK: - Context-menu selection actions

    var defaultSearchProviderName: String? {
        guard let store else { return nil }
        return NavigationService.defaultSearchProvider(for: store.defaultSearchProviderID).name
    }

    func searchInNewTab(_ query: String) {
        guard let store else { return }
        let provider = NavigationService.defaultSearchProvider(for: store.defaultSearchProviderID)
        guard let url = provider.searchURL(for: query) else { return }
        store.navigateNewTab(to: url)
    }

    func register(_ webView: WKWebView, for tabID: UUID) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        (webView as? BrowserWebView)?.coordinator = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = WebInspectorConfiguration.isEnabled
        // Keep WebKit's native under-page color derivation. It samples the
        // page's html/body backgrounds, which lets the scrollbar gutter match
        // light and dark sites independently of Candoa's interface appearance.
        applyWebsiteAppearance(to: webView)

        // Popup web views (createWebViewWith) arrive carrying the source
        // page's configuration, whose content controller is already set up;
        // re-adding a message handler by the same name throws NSException.
        let contentController = webView.configuration.userContentController
        if let contentRuleList, strictTrackingProtectionEnabled {
            contentController.remove(contentRuleList)
            contentController.add(contentRuleList)
        }
        contentController.removeScriptMessageHandler(forName: WebPageScripts.mediaStateMessageName)
        contentController.add(self, name: WebPageScripts.mediaStateMessageName)
        contentController.removeScriptMessageHandler(forName: WebPageScripts.linkHoverMessageName)
        contentController.add(self, name: WebPageScripts.linkHoverMessageName)
        contentController.removeScriptMessageHandler(forName: WebPageScripts.webStoreInstallMessageName)
        contentController.add(self, name: WebPageScripts.webStoreInstallMessageName)
        addUserScriptOnce(
            WebPageScripts.mediaObserverScript,
            to: contentController,
            forMainFrameOnly: true
        )
        addUserScriptOnce(
            WebPageScripts.linkHoverObserverScript,
            to: contentController,
            // Every frame: links inside embeds deserve a preview too.
            forMainFrameOnly: false
        )
        addUserScriptOnce(
            WebPageScripts.youtubeMiniplayerGuardScript,
            to: contentController,
            forMainFrameOnly: true
        )
        addUserScriptOnce(
            WebPageScripts.chromeWebStoreScript,
            to: contentController,
            forMainFrameOnly: true
        )
        if BrowserStore.isUITesting {
            addUserScriptOnce(
                "window.__candoaInitialDark = matchMedia('(prefers-color-scheme: dark)').matches",
                to: contentController,
                forMainFrameOnly: true
            )
            contentController.removeScriptMessageHandler(forName: WebPageScripts.popupDiagnosticsMessageName)
            contentController.add(self, name: WebPageScripts.popupDiagnosticsMessageName)
            addUserScriptOnce(
                WebPageScripts.popupDiagnosticsScript,
                to: contentController,
                forMainFrameOnly: true
            )
        }
        webViews[tabID] = webView
        tabIDsByWebView.setObject(tabID.uuidString as NSString, forKey: webView)
        observe(webView, tabID: tabID)
    }

    private func addUserScriptOnce(
        _ source: String,
        to contentController: WKUserContentController,
        forMainFrameOnly: Bool
    ) {
        guard !contentController.userScripts.contains(where: { $0.source == source }) else { return }
        contentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: forMainFrameOnly)
        )
    }

    func updateWebsiteAppearance(
        _ appearance: WebsiteAppearance,
        systemUsesDarkAppearance: Bool
    ) {
        guard self.websiteAppearance != appearance
                || self.systemUsesDarkAppearance != systemUsesDarkAppearance else {
            return
        }

        self.websiteAppearance = appearance
        self.systemUsesDarkAppearance = systemUsesDarkAppearance
        webViews.values.forEach(applyWebsiteAppearance(to:))
        refreshServerThemeOverrides()
    }

    func applyWebsiteAppearance(to webView: WKWebView) {
        let appearanceName: NSAppearance.Name = usesDarkWebsiteAppearance ? .darkAqua : .aqua
        guard webView.appearance?.name != appearanceName else { return }
        webView.appearance = NSAppearance(named: appearanceName)
    }

    var usesDarkWebsiteAppearance: Bool {
        switch websiteAppearance {
        case .automatic:
            return systemUsesDarkAppearance
        case .light:
            return false
        case .dark:
            return true
        }
    }

    func refreshServerThemeOverrides() {
        for (tabID, webView) in webViews {
            guard let url = webView.url, WebsiteAppearanceService.preparesServerTheme(for: url) else { continue }

            let token = UUID()
            pendingAppearanceNavigationTokens[tabID] = token
            WebsiteAppearanceService.prepareServerTheme(
                for: url,
                in: webView.configuration.websiteDataStore,
                usesDarkAppearance: usesDarkWebsiteAppearance
            ) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.pendingAppearanceNavigationTokens[tabID] == token else { return }
                self.pendingAppearanceNavigationTokens[tabID] = nil
                webView.reload()
            }
        }
    }

    func ensureLoaded(_ tab: BrowserTab) {
        // Popup web views own their first navigation; loading here would sever window.opener.
        guard !popupTabIDsAwaitingFirstLoad.contains(tab.id), !tab.isWelcomePage else { return }

        let webView = webView(for: tab)

        // A hibernation wake-up owns this web view's navigation until commit;
        // the URL mismatch below is expected while the restore is in flight.
        guard !restoringTabIDs.contains(tab.id) else { return }

        guard let expectedURL = tab.url else { return }

        // A navigation that became a download never commits; re-requesting
        // its URL here would restart the download on every SwiftUI pass.
        guard !downloadConvertedTabIDs.contains(tab.id) else { return }

        // A destination that failed before committing is left to the recovery
        // card's retry; re-requesting it here would loop.
        guard failedProvisionalURLs[tab.id]?.absoluteString != expectedURL.absoluteString else { return }

        if webView.url?.absoluteString != expectedURL.absoluteString {
            load(expectedURL, in: tab.id)
        }
    }

    func load(_ url: URL, in tabID: UUID) {
        guard url != BrowserInternalPage.welcomeURL else { return }
        // Every explicit request — address bar, retry button, link, restore —
        // ends the quarantine: this navigation gets its own chance to fail.
        // ensureLoaded returns before reaching here while a tab is quarantined,
        // so clearing it cannot re-open the loop.
        failedProvisionalURLs[tabID] = nil
        let url = store?.navigationService.preferredLocaleURL(for: url) ?? url
        let webView = webViews[tabID]
        let targetWebView: WKWebView

        if let target = store?.navigationService.webAppPromptForwardingTarget(for: url) {
            pendingWebAppPrompts[tabID] = PendingWebAppPrompt(providerID: target.providerID, query: target.query)
        } else {
            pendingWebAppPrompts[tabID] = nil
        }

        if let webView {
            targetWebView = webView
        } else if let tab = store?.tabs.first(where: { $0.id == tabID }) {
            // Waking via webView(for:) first keeps the hibernated tab's
            // back/forward history underneath the new navigation.
            targetWebView = hibernatedInteractionStates[tab.id] != nil
                ? self.webView(for: tab)
                : makeWebView(for: tab)
        } else {
            let fallbackSpaceID = store?.activeSpaceID ?? UUID()
            targetWebView = makeWebView(
                for: BrowserTab(
                    id: tabID,
                    title: url.absoluteString,
                    url: url,
                    spaceID: fallbackSpaceID
                )
            )
        }

        // Localhost is included so developer-bar tests can exercise real
        // local-development URLs without a server: neither the app nor the
        // UI-test runner carries the network-server entitlement, so tests
        // cannot host one.
        if BrowserStore.isUITesting,
           url.host == "fixture.candoa.test" || url.isLocalDevelopment,
           let fixtureHTML = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PAGE_HTML"] {
            targetWebView.loadHTMLString(fixtureHTML, baseURL: url)
            return
        }

        if url.isFileURL {
            // WebKit needs an explicit read grant for sandboxed local files.
            // Grant only the chosen file, never its folder — a page's sibling
            // subresources are the documented cost of the narrow grant.
            pendingAppearanceNavigationTokens[tabID] = nil
            targetWebView.loadFileURL(url, allowingReadAccessTo: url)
            return
        }

        let request = request(for: url)
        guard WebsiteAppearanceService.preparesServerTheme(for: url) else {
            pendingAppearanceNavigationTokens[tabID] = nil
            targetWebView.load(request)
            return
        }

        let token = UUID()
        pendingAppearanceNavigationTokens[tabID] = token
        WebsiteAppearanceService.prepareServerTheme(
            for: url,
            in: targetWebView.configuration.websiteDataStore,
            usesDarkAppearance: usesDarkWebsiteAppearance
        ) { [weak self, weak targetWebView] in
            guard let self,
                  let targetWebView,
                  self.pendingAppearanceNavigationTokens[tabID] == token else { return }
            self.pendingAppearanceNavigationTokens[tabID] = nil
            targetWebView.load(request)
        }
    }

    /// Produces the page's web-archive bytes from the live web view. No
    /// snapshot or duplicate view is retained — WebKit serializes the loaded
    /// page directly. The completion is main-actor-isolated (and therefore
    /// Sendable across WebKit's @Sendable handler); WebKit already calls
    /// back on the main thread, so the hop only makes that provable.
    func createWebArchiveData(
        for tabID: UUID,
        completion: @escaping @MainActor (Result<Data, any Error>) -> Void
    ) {
        guard let webView = webViews[tabID] else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        webView.createWebArchiveData { result in
            MainActor.assumeIsolated { completion(result) }
        }
    }

    /// Produces a full-content PDF of the loaded page through WebKit's
    /// supported single-pass renderer. Same isolation contract as
    /// `createWebArchiveData`.
    func createPDFData(
        for tabID: UUID,
        completion: @escaping @MainActor (Result<Data, any Error>) -> Void
    ) {
        guard let webView = webViews[tabID] else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        webView.createPDF { result in
            MainActor.assumeIsolated { completion(result) }
        }
    }

    func removeWebView(for tabID: UUID) {
        removeWebView(for: tabID, keepingHibernationData: false)
    }

    /// Tears down every web view and all in-memory page residue —
    /// hibernated interaction states, wake snapshots, restore overlays.
    /// Called when a private window closes so nothing of the session
    /// outlives it beyond the deallocation of the data store itself.
    func purgeAllWebContent() {
        stopMemoryPressureMonitoring()
        for tabID in Array(webViews.keys) {
            removeWebView(for: tabID)
        }
        hibernatedInteractionStates.removeAll()
        wakeSnapshots.removeAll()
        restoringTabIDs.removeAll()
        failedProvisionalURLs.removeAll()
    }

    func hasLoadedWebView(for tabID: UUID) -> Bool {
        webViews[tabID] != nil
    }

    func removeWebView(for tabID: UUID, keepingHibernationData: Bool) {
        store?.setLoading(false, for: tabID)
        if !keepingHibernationData {
            hibernatedInteractionStates[tabID] = nil
            wakeSnapshots[tabID] = nil
        }
        restoringTabIDs.remove(tabID)
        failedProvisionalURLs[tabID] = nil
        removeRestoreOverlay(for: tabID)

        guard let webView = webViews.removeValue(forKey: tabID) else { return }
        clearReaderState(for: tabID)
        pendingWebAppPrompts[tabID] = nil
        observations[tabID] = nil
        pendingAppearanceNavigationTokens[tabID] = nil
        popupTabIDsAwaitingFirstLoad.remove(tabID)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebPageScripts.mediaStateMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebPageScripts.linkHoverMessageName
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebPageScripts.webStoreInstallMessageName
        )
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        tabIDsByWebView.removeObject(forKey: webView)
        if hostedActiveTabID == tabID {
            hostedActiveTabID = nil
        }
        if miniPlayerHostedTabID == tabID {
            miniPlayerHostedTabID = nil
        }
        if miniPlayerSummon?.tabID == tabID {
            miniPlayerSummon = nil
        }
    }

    /// The most recent search-results page behind the current one, if the tab
    /// reached here from a search. Safari's Return to Search Results walks the
    /// back list rather than stepping back one page at a time.
    func lastSearchResultsItem(tabID: UUID, matches: (URL) -> Bool) -> WKBackForwardListItem? {
        guard let webView = webViews[tabID] else { return nil }
        return webView.backForwardList.backList.last(where: { matches($0.url) })
    }

    func go(to item: WKBackForwardListItem, in tabID: UUID) {
        webViews[tabID]?.go(to: item)
    }

    func goBack(tabID: UUID) {
        webViews[tabID]?.goBack()
    }

    func goForward(tabID: UUID) {
        webViews[tabID]?.goForward()
    }

    func reload(tabID: UUID) {
        webViews[tabID]?.reload()
    }

    func reloadFromOrigin(tabID: UUID) {
        webViews[tabID]?.reloadFromOrigin()
    }

    func stopLoading(tabID: UUID) {
        webViews[tabID]?.stopLoading()
    }

    /// Where the current match sits among all of them, for the find bar's
    /// "3 of 27 matches". `isCountExact` is false on the native fallback path,
    /// which can only report whether something was found.
    struct FindTally {
        static let none = FindTally(index: 0, count: 0, isCountExact: true)

        let index: Int
        let count: Int
        let isCountExact: Bool
    }

    /// Highlights every match and steps the current one, the way Safari does.
    /// `WKFindConfiguration` only moves the page selection, which WebKit stops
    /// painting once the find field takes keyboard focus, so the highlighting
    /// runs in the page (see `WebPageScripts.findScript`). Pages without the
    /// CSS Custom Highlight API fall back to the native selection.
    func find(_ query: String, forward: Bool, in tabID: UUID, completion: ((FindTally) -> Void)? = nil) {
        guard let webView = webViews[tabID], !query.isEmpty else {
            completion?(.none)
            return
        }

        webView.evaluateJavaScript(WebPageScripts.findScript(query: query, forward: forward)) { value, error in
            let result = value as? [String: Any]
            guard error == nil, result?["supported"] as? Bool == true else {
                self.findUsingPageSelection(query, forward: forward, in: webView, completion: completion)
                return
            }

            completion?(FindTally(
                index: result?["index"] as? Int ?? 0,
                count: result?["count"] as? Int ?? 0,
                isCountExact: true
            ))
        }
    }

    private func findUsingPageSelection(
        _ query: String,
        forward: Bool,
        in webView: WKWebView,
        completion: ((FindTally) -> Void)?
    ) {
        let configuration = WKFindConfiguration()
        configuration.wraps = true
        configuration.caseSensitive = false
        configuration.backwards = !forward

        webView.find(query, configuration: configuration) { result in
            // The native path knows only whether it landed on something, so
            // the find bar shows no tally rather than a made-up one.
            completion?(FindTally(index: 0, count: result.matchFound ? 1 : 0, isCountExact: false))
        }
    }

    func clearFindSelection(in tabID: UUID) {
        guard let webView = webViews[tabID] else { return }
        webView.evaluateJavaScript(WebPageScripts.findClearScript)
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    /// The page's full text-node content (see `plainPageTextScript`), used
    /// for evidence checks that the readable extraction would miss.
    func plainPageText(for tabID: UUID) async -> String? {
        guard let webView = webViews[tabID] else { return nil }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebPageScripts.plainPageTextScript) { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: value as? String)
            }
        }
    }

    func readablePageText(for tabID: UUID) async -> String? {
        guard let webView = webViews[tabID] else { return nil }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebPageScripts.readablePageTextScript) { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: value as? String)
            }
        }
    }

    /// Gives a just-loaded, script-rendered page a short bounded window to finish
    /// exposing its semantic content before Ask captures the page. This runs only
    /// for a user-initiated Ask request and does not leave observers or timers behind.
    func waitForAIPageContextSettled(for tabID: UUID) async {
        guard let webView = webViews[tabID] else { return }
        let expectedURL = store?.tabs.first(where: { $0.id == tabID })?.url
        var stableChecks = 0

        for _ in 0..<16 {
            guard !Task.isCancelled else { return }
            let reachedExpectedPage: Bool
            if let expectedURL, let currentURL = webView.url {
                reachedExpectedPage = currentURL.scheme == expectedURL.scheme
                    && currentURL.host == expectedURL.host
                    && currentURL.path == expectedURL.path
            } else {
                reachedExpectedPage = expectedURL == nil && webView.url != nil
            }

            if reachedExpectedPage && !webView.isLoading {
                stableChecks += 1
                if stableChecks >= 3 { return }
            } else {
                stableChecks = 0
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func visiblePageControlsText(for tabID: UUID) async -> String? {
        guard let webView = webViews[tabID] else { return nil }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebPageScripts.visiblePageControlsScript) { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: value as? String)
            }
        }
    }

    func browserAgentSnapshot(for tabID: UUID) async -> BrowserAgentSnapshot? {
        guard let webView = webViews[tabID] else { return nil }
        let snapshotID = UUID()

        do {
            return try await browserAgentDriver.snapshot(in: webView, id: snapshotID)
        } catch {
            return nil
        }
    }

    /// Waits for the page to stop changing after an agent action and
    /// returns how many DOM mutations it saw (nil when the page could not be
    /// observed). Client-rendered pages change long after a click returns;
    /// watching the DOM instead of sleeping a fixed beat lands the next
    /// snapshot after the change, and a zero tells the model the click did
    /// nothing.
    func waitForBrowserAgentPageSettled(for tabID: UUID, previousURL: String) async -> Int? {
        guard let webView = webViews[tabID] else { return nil }

        // A navigation tears the document down; a settle observer on the
        // old document would resolve with nothing. Let the load finish first.
        for _ in 0..<40 {
            guard !Task.isCancelled else { return nil }
            if !webView.isLoading { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let report = await browserAgentDriver.waitForSettle(in: webView)
        // The settle may have been the start of a navigation; wait that out too.
        for _ in 0..<40 {
            guard !Task.isCancelled else { return report?.mutations }
            if !webView.isLoading { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if webView.url?.absoluteString != previousURL {
            // New document: give its scripts one settle window as well.
            try? await Task.sleep(for: .milliseconds(150))
            await browserAgentDriver.waitForSettle(in: webView, quiet: .milliseconds(300), timeout: .seconds(2))
        }
        return report?.mutations
    }

    func performAIPageAction(_ action: PageActionProposal, for tabID: UUID) async -> PageActionResult {
        guard let webView = webViews[tabID] else {
            return .failed("That page is not ready for an action.")
        }
        if let expectedURL = action.browserAgentPageURL,
           webView.url?.absoluteString != expectedURL {
            return .failed("Candoa stopped because the page changed after it was inspected.")
        }
        do {
            return try await browserAgentDriver.performAction(action, in: webView)
        } catch BrowserAgentDriver.DriverError.actionNotGrounded {
            return .failed("Candoa stopped because this action was not grounded in the latest page inspection.")
        } catch {
            return .failed("Candoa could not complete that referenced action.")
        }
    }

    func captureVisiblePage(for tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let webView = webViews[tabID], !webView.bounds.isEmpty else {
            completion(nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))

        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image)
        }
    }

    func zoomIn(tabID: UUID) {
        adjustZoom(tabID: tabID, direction: 1)
    }

    func zoomOut(tabID: UUID) {
        adjustZoom(tabID: tabID, direction: -1)
    }

    func resetZoom(tabID: UUID) {
        webViews[tabID]?.pageZoom = 1
    }

    func adjustZoom(tabID: UUID, direction: Int) {
        guard let webView = webViews[tabID] else { return }
        let levels = Self.pageZoomLevels
        let currentIndex = levels.enumerated().min {
            abs($0.element - webView.pageZoom) < abs($1.element - webView.pageZoom)
        }?.offset ?? levels.firstIndex(of: 1) ?? 0
        let nextIndex = min(max(currentIndex + direction, 0), levels.count - 1)
        webView.pageZoom = levels[nextIndex]
    }

    // MARK: - Content Blocking

    var strictTrackingProtectionEnabled: Bool {
        SettingsOption.bool(SettingsOption.strictTrackingProtection, default: true)
    }

    func applyContentRuleList() async {
        guard contentRuleList == nil, let ruleList = await ContentBlockerService.shared.ruleList() else { return }
        contentRuleList = ruleList

        // Web views created before compilation finished pick the rules up
        // for their subsequent loads.
        if strictTrackingProtectionEnabled {
            appliedTrackingProtection = true
            for webView in webViews.values {
                webView.configuration.userContentController.add(ruleList)
            }
        }
    }

    private func userDefaultsDidChange() {
        store?.syncFloatingMiniPlayerPreference()
        guard let contentRuleList, strictTrackingProtectionEnabled != appliedTrackingProtection else { return }
        appliedTrackingProtection.toggle()

        for webView in webViews.values {
            let contentController = webView.configuration.userContentController
            // The tracker list is the only rule list Candoa ever attaches.
            contentController.removeAllContentRuleLists()
            if appliedTrackingProtection {
                contentController.add(contentRuleList)
            }
        }
    }

    func navigationState(for tabID: UUID) -> (canGoBack: Bool, canGoForward: Bool) {
        guard let webView = webViews[tabID] else {
            return (false, false)
        }

        return (webView.canGoBack, webView.canGoForward)
    }

    /// Prints through WKWebView's own print operation and the system print
    /// panel — pagination, orientation, scale, and presets all belong to
    /// AppKit. The operation renders into its own print view; the live web
    /// view is never resized or snapshotted, and nothing is retained after
    /// the panel closes (cancelled or printed).
    func printPage(for tabID: UUID) {
        guard let webView = webViews[tabID], webView.url != nil else { return }

        // NSPrintInfo.shared carries the user's presets; a copy keeps this
        // job from mutating them.
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let operation = webView.printOperation(with: printInfo)
        // WKWebView's print view starts zero-sized; without a real frame the
        // job renders blank pages.
        operation.view?.frame = webView.bounds
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling])

        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func snapshotImage(for tabID: UUID, width: CGFloat, completion: @escaping (NSImage?) -> Void) {
        guard
            let webView = webViews[tabID],
            !webView.bounds.isEmpty
        else {
            completion(nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(value: Double(width))

        webView.takeSnapshot(with: configuration) { image, _ in
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

}
