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
    static let browserUserAgentApplicationName: String = {
        let safariVersion = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap(Bundle.init(url:))?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        return "Version/\(safariVersion ?? fallbackSafariVersion) "
            + "Safari/605.1.15 Candoa/\(appVersion ?? "0")"
    }()

    static var fallbackSafariVersion: String {
        let macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safariMajorVersion = macOSMajorVersion >= 26 ? macOSMajorVersion : macOSMajorVersion + 3
        return "\(safariMajorVersion).0"
    }

    weak var store: BrowserStore?
    var webViews: [UUID: WKWebView] = [:]
    var tabIDsByWebView = NSMapTable<WKWebView, NSString>.weakToStrongObjects()
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    var pendingWebAppPrompts: [UUID: PendingWebAppPrompt] = [:]
    var popupTabIDsAwaitingFirstLoad = Set<UUID>()
    var activeDownloads = Set<WKDownload>()
    var downloadDestinations: [WKDownload: URL] = [:]
    var hostedActiveTabID: UUID?
    var miniPlayerHostedTabID: UUID?
    var contentRuleList: WKContentRuleList?
    var hibernatedInteractionStates: [UUID: Data] = [:]
    var wakeSnapshots: [UUID: NSImage] = [:]
    var restoringTabIDs = Set<UUID>()
    var restoreOverlays: [UUID: NSImageView] = [:]
    var hibernationScanTask: Task<Void, Never>?
    var websiteAppearance = WebsiteAppearance.dark
    var systemUsesDarkAppearance = false
    var pendingAppearanceNavigationTokens: [UUID: UUID] = [:]

    func attach(store: BrowserStore) {
        self.store = store

        Task { [weak self] in
            await self?.applyContentRuleList()
        }

        hibernationScanTask?.cancel()
        hibernationScanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(TabHibernationConfiguration.scanInterval * 1_000_000_000)
                )
                self?.hibernateIdleWebViews()
            }
        }
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let existingWebView = webViews[tab.id] {
            return existingWebView
        }

        let webView = makeWebView(for: tab)

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

    func makeWebView(for tab: BrowserTab) -> WKWebView {
        let dataStoreID = store?.dataStoreID(for: tab.spaceID) ?? tab.spaceID
        let dataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)

        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        // WKWebView's embedded user agent omits Safari's compatibility tokens,
        // causing sites such as Google to serve a reduced fallback experience.
        configuration.applicationNameForUserAgent = Self.browserUserAgentApplicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: configuration)
        register(webView, for: tab.id)
        return webView
    }

    func register(_ webView: WKWebView, for tabID: UUID) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = WebInspectorConfiguration.isEnabled
        // Keep WebKit's native under-page color derivation. It samples the
        // page's html/body backgrounds, which lets the scrollbar gutter match
        // light and dark sites independently of Candoa's interface appearance.
        applyWebsiteAppearance(to: webView)

        let contentController = webView.configuration.userContentController
        if let contentRuleList {
            contentController.add(contentRuleList)
        }
        contentController.add(self, name: WebPageScripts.mediaStateMessageName)
        contentController.addUserScript(
            WKUserScript(
                source: WebPageScripts.mediaObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if BrowserStore.isUITesting {
            contentController.addUserScript(
                WKUserScript(
                    source: "window.__candoaInitialDark = matchMedia('(prefers-color-scheme: dark)').matches",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }
        webViews[tabID] = webView
        tabIDsByWebView.setObject(tabID.uuidString as NSString, forKey: webView)
        observe(webView, tabID: tabID)
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

        if webView.url?.absoluteString != expectedURL.absoluteString {
            load(expectedURL, in: tab.id)
        }
    }

    func load(_ url: URL, in tabID: UUID) {
        guard url != BrowserInternalPage.welcomeURL else { return }
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

        if BrowserStore.isUITesting,
           url.host == "fixture.candoa.test",
           let fixtureHTML = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PAGE_HTML"] {
            targetWebView.loadHTMLString(fixtureHTML, baseURL: url)
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

    func removeWebView(for tabID: UUID) {
        removeWebView(for: tabID, keepingHibernationData: false)
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
        removeRestoreOverlay(for: tabID)

        guard let webView = webViews.removeValue(forKey: tabID) else { return }
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
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        tabIDsByWebView.removeObject(forKey: webView)
        if hostedActiveTabID == tabID {
            hostedActiveTabID = nil
        }
        if miniPlayerHostedTabID == tabID {
            miniPlayerHostedTabID = nil
        }
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

    func stopLoading(tabID: UUID) {
        webViews[tabID]?.stopLoading()
    }

    func find(_ query: String, forward: Bool, in tabID: UUID, completion: ((Bool) -> Void)? = nil) {
        guard let webView = webViews[tabID], !query.isEmpty else {
            completion?(false)
            return
        }

        let configuration = WKFindConfiguration()
        configuration.wraps = true
        configuration.caseSensitive = false
        configuration.backwards = !forward

        webView.find(query, configuration: configuration) { result in
            completion?(result.matchFound)
        }
    }

    func clearFindSelection(in tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.getSelection().removeAllRanges()")
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

    func browserAgentSnapshot(for tabID: UUID) async -> CandoaBrowserAgentSnapshot? {
        guard let webView = webViews[tabID] else { return nil }
        let snapshotID = UUID()

        do {
            let script = """
            (() => {
              const snapshotID = \(javaScriptStringLiteral(for: snapshotID.uuidString.lowercased()));
              \(WebPageScripts.browserAgentControlsScript)
            })();
            """
            let value = try await evaluateBrowserAgentJavaScript(script, in: webView)
            guard let data = value.data(using: String.Encoding.utf8) else { return nil }
            let controls = try JSONDecoder().decode([CandoaBrowserAgentControl].self, from: data)
            return CandoaBrowserAgentSnapshot(id: snapshotID, controls: controls)
        } catch {
            return nil
        }
    }

    func waitForBrowserAgentPageSettled(for tabID: UUID, previousURL: String) async {
        guard let webView = webViews[tabID] else { return }

        // Client-rendered configurators often unlock the next choice without a
        // WebKit navigation. Give that bounded transition time to commit before
        // the agent observes the page again.
        try? await Task.sleep(for: .milliseconds(650))
        for _ in 0..<12 {
            guard !Task.isCancelled else { return }
            if !webView.isLoading {
                try? await Task.sleep(for: .milliseconds(250))
                if !webView.isLoading { return }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func pagePurchaseCandidates(for tabID: UUID) async -> [CandoaPagePurchaseCandidate] {
        guard let webView = webViews[tabID] else { return [] }

        let value: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebPageScripts.pagePurchaseCandidatesScript) { value, error in
                continuation.resume(returning: error == nil ? value as? String : nil)
            }
        }
        guard let value, let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CandoaPagePurchaseCandidate].self, from: data)) ?? []
    }

    func performAIPageAction(_ action: CandoaPageActionProposal, for tabID: UUID) async -> String {
        guard let webView = webViews[tabID] else { return "That page is not ready for an action." }
        if let expectedURL = action.browserAgentPageURL,
           webView.url?.absoluteString != expectedURL {
            return "Candoa stopped because the page changed after it was inspected."
        }
        if action.kind == .scroll, let snapshotID = action.browserAgentSnapshotID {
            do {
                let value = try await webView.callAsyncJavaScript(
                    """
                    return (() => {
                      if (window.__candoaAgentSnapshotID !== snapshotID) {
                        return "Candoa stopped because the page changed after it was inspected.";
                      }
                      const distance = Math.max(300, innerHeight * 0.8);
                      window.scrollBy({
                        top: direction === "up" ? -distance : distance,
                        behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
                      });
                      return `Scrolled ${direction}.`;
                    })();
                    """,
                    arguments: [
                        "snapshotID": snapshotID.uuidString.lowercased(),
                        "direction": action.target,
                    ],
                    in: nil,
                    contentWorld: Self.browserAgentContentWorld
                )
                return value as? String ?? "Action completed."
            } catch {
                return "Candoa could not complete that referenced action."
            }
        }
        if let ref = action.browserAgentReference,
           let snapshotID = action.browserAgentSnapshotID,
           let controlKind = action.browserAgentControlKind {
            do {
                let script = """
                (() => {
                  const snapshotID = \(javaScriptStringLiteral(for: snapshotID.uuidString.lowercased()));
                  const ref = \(javaScriptStringLiteral(for: ref));
                  const expectedLabel = \(javaScriptStringLiteral(for: action.target));
                  const expectedKind = \(javaScriptStringLiteral(for: controlKind.rawValue));
                  const kind = \(javaScriptStringLiteral(for: action.kind.rawValue));
                  const value = \(javaScriptStringLiteral(for: action.value ?? ""));
                  \(WebPageScripts.browserAgentActionScript)
                })();
                """
                let value = try await evaluateBrowserAgentJavaScript(script, in: webView)
                return value
            } catch {
                return "Candoa could not complete that referenced action."
            }
        }
        let payload = ["kind": action.kind.rawValue, "target": action.target, "value": action.value ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return "Candoa could not prepare that action."
        }

        let script = """
        (() => {
          const action = \(payloadJSON);
          const visible = (element) => {
            if (!(element instanceof HTMLElement) || element.closest('[aria-hidden=true],[hidden]')) return false;
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 2 && rect.height > 2 && style.display !== 'none' && style.visibility !== 'hidden';
          };
          const clean = (value) => String(value || '').replace(/[\\s\\n\\r\\t]+/g, ' ').trim();
          const label = (element) => {
            const labelledBy = clean(element.getAttribute('aria-labelledby')).split(' ').map(id => clean(document.getElementById(id)?.innerText || document.getElementById(id)?.textContent)).filter(Boolean).join(' ');
            const explicitLabel = element.id ? clean(document.querySelector(`label[for="${CSS.escape(element.id)}"]`)?.innerText) : '';
            return [element.getAttribute('aria-label'), labelledBy, explicitLabel, element.closest('label')?.innerText, element.placeholder, element.title, element.innerText, element.textContent, element.value].map(clean).find(Boolean) || '';
          };
          if (action.kind === 'navigate') return 'Navigation must be approved and performed by Candoa.';
          if (action.kind === 'scroll') { window.scrollBy({ top: action.target === 'up' ? -Math.max(300, innerHeight * 0.8) : Math.max(300, innerHeight * 0.8), behavior: 'smooth' }); return 'Scrolled ' + action.target + '.'; }
          const selectors = action.kind === 'fill'
            ? 'input:not([type=radio]):not([type=checkbox]),textarea,[contenteditable=true],[role=textbox],[role=searchbox]'
            : action.kind === 'select'
              ? 'select,label[for],[role=radio],[role=option],[role=checkbox],input[type=radio],input[type=checkbox]'
              : 'a[href],button,label[for],[role=button],[role=link],input[type=submit],input[type=button]';
          const target = action.target.toLocaleLowerCase();
          const candidates = Array.from(document.querySelectorAll(selectors)).filter(candidate => visible(candidate));
          const element = candidates.find(candidate => label(candidate).toLocaleLowerCase() === target)
            || candidates.find(candidate => label(candidate).toLocaleLowerCase().includes(target));
          if (!element) return 'I could not find a visible control matching "' + action.target + '".';
          if (action.kind === 'click') { element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }); element.click(); return 'Clicked "' + label(element) + '".'; }
          if (action.kind === 'select') {
            element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
            if (element instanceof HTMLSelectElement) {
              const requested = clean(action.value).toLocaleLowerCase();
              const option = Array.from(element.options).find(candidate => clean(candidate.label).toLocaleLowerCase() === requested || clean(candidate.value).toLocaleLowerCase() === requested);
              if (!option) return 'I could not find the requested option in "' + label(element) + '".';
              element.focus();
              element.value = option.value;
              element.dispatchEvent(new Event('input', { bubbles: true }));
              element.dispatchEvent(new Event('change', { bubbles: true }));
              return 'Selected "' + clean(option.label) + '" in "' + label(element) + '".';
            }
            const activationElement = element instanceof HTMLInputElement
              && (element.type === 'radio' || element.type === 'checkbox')
              && element.id
              ? document.querySelector(`label[for="${CSS.escape(element.id)}"]`) || element
              : element;
            activationElement.click();
            return 'Selected "' + label(element) + '".';
          }
          if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) { element.focus(); element.value = action.value; element.dispatchEvent(new Event('input', { bubbles: true })); element.dispatchEvent(new Event('change', { bubbles: true })); return 'Filled "' + label(element) + '".'; }
          element.focus(); element.textContent = action.value; element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: action.value })); return 'Filled "' + label(element) + '".';
        })();
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: error == nil ? (value as? String ?? "Action completed.") : "Candoa could not complete that action.")
            }
        }
    }

    private func evaluateBrowserAgentJavaScript(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(
                script,
                in: nil,
                in: Self.browserAgentContentWorld
            ) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: value as? String ?? "")
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
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

    func applyContentRuleList() async {
        guard contentRuleList == nil, let ruleList = await ContentBlockerService.shared.ruleList() else { return }
        contentRuleList = ruleList

        // Web views created before compilation finished pick the rules up
        // for their subsequent loads.
        for webView in webViews.values {
            webView.configuration.userContentController.add(ruleList)
        }
    }

    func navigationState(for tabID: UUID) -> (canGoBack: Bool, canGoForward: Bool) {
        guard let webView = webViews[tabID] else {
            return (false, false)
        }

        return (webView.canGoBack, webView.canGoForward)
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
