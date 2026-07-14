import AppKit
import Foundation
import WebKit

@MainActor
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private struct PendingWebAppPrompt {
        let providerID: String
        let query: String
    }

    private static let acceptLanguageHeader = "en-US,en;q=0.9"
    private static let desktopSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let pageZoomLevels: [CGFloat] = [0.5, 0.65, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private weak var store: BrowserStore?
    private var webViews: [UUID: WKWebView] = [:]
    private var tabIDsByWebView = NSMapTable<WKWebView, NSString>.weakToStrongObjects()
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var pendingWebAppPrompts: [UUID: PendingWebAppPrompt] = [:]
    private var popupTabIDsAwaitingFirstLoad = Set<UUID>()
    private var activeDownloads = Set<WKDownload>()
    private var downloadDestinations: [WKDownload: URL] = [:]
    private var hostedActiveTabID: UUID?
    private var miniPlayerHostedTabID: UUID?
    private var contentRuleList: WKContentRuleList?
    private var hibernatedInteractionStates: [UUID: Data] = [:]
    private var wakeSnapshots: [UUID: NSImage] = [:]
    private var restoringTabIDs = Set<UUID>()
    private var restoreOverlays: [UUID: NSImageView] = [:]
    private var hibernationScanTask: Task<Void, Never>?

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

    private func makeWebView(for tab: BrowserTab) -> WKWebView {
        let dataStoreID = store?.dataStoreID(for: tab.spaceID) ?? tab.spaceID
        let dataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)

        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: configuration)
        register(webView, for: tab.id)
        return webView
    }

    private func register(_ webView: WKWebView, for tabID: UUID) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = WebInspectorConfiguration.isEnabled
        webView.customUserAgent = Self.desktopSafariUserAgent
        webView.underPageBackgroundColor = .textBackgroundColor

        // Let web content inherit the window appearance so websites that honor
        // `prefers-color-scheme` can follow the active system/space setting.
        // Keep transparent document regions readable while matching the
        // active macOS appearance instead of forcing a white page backing.

        let contentController = webView.configuration.userContentController
        if let contentRuleList {
            contentController.add(contentRuleList)
        }
        contentController.add(self, name: Self.mediaStateMessageName)
        contentController.addUserScript(
            WKUserScript(
                source: Self.mediaObserverScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        webViews[tabID] = webView
        tabIDsByWebView.setObject(tabID.uuidString as NSString, forKey: webView)
        observe(webView, tabID: tabID)
    }

    func ensureLoaded(_ tab: BrowserTab) {
        // Popup web views own their first navigation; loading here would sever window.opener.
        guard !popupTabIDsAwaitingFirstLoad.contains(tab.id) else { return }

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

        targetWebView.load(request(for: url))
    }

    func removeWebView(for tabID: UUID) {
        removeWebView(for: tabID, keepingHibernationData: false)
    }

    func hasLoadedWebView(for tabID: UUID) -> Bool {
        webViews[tabID] != nil
    }

    private func removeWebView(for tabID: UUID, keepingHibernationData: Bool) {
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
        popupTabIDsAwaitingFirstLoad.remove(tabID)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.mediaStateMessageName)
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
            webView.evaluateJavaScript(Self.readablePageTextScript) { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: value as? String)
            }
        }
    }

    func visiblePageControlsText(for tabID: UUID) async -> String? {
        guard let webView = webViews[tabID] else { return nil }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(Self.visiblePageControlsScript) { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: value as? String)
            }
        }
    }

    func performAIPageAction(_ action: CandoaPageActionProposal, for tabID: UUID) async -> String {
        guard let webView = webViews[tabID] else { return "That page is not ready for an action." }
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
            return rect.width > 2 && rect.height > 2 && rect.bottom >= 0 && rect.right >= 0 && rect.top <= innerHeight && rect.left <= innerWidth && style.display !== 'none' && style.visibility !== 'hidden';
          };
          const label = (element) => [element.getAttribute('aria-label'), element.placeholder, element.title, element.value, element.innerText, element.textContent].map(value => String(value || '').trim()).find(Boolean) || '';
          if (action.kind === 'scroll') { window.scrollBy({ top: action.target === 'up' ? -Math.max(300, innerHeight * 0.8) : Math.max(300, innerHeight * 0.8), behavior: 'smooth' }); return 'Scrolled ' + action.target + '.'; }
          const selectors = action.kind === 'fill' ? 'input,textarea,[contenteditable=true]' : 'a[href],button,[role=button],[role=link],input[type=submit],input[type=button]';
          const target = action.target.toLocaleLowerCase();
          const element = Array.from(document.querySelectorAll(selectors)).find(candidate => visible(candidate) && label(candidate).toLocaleLowerCase().includes(target));
          if (!element) return 'I could not find a visible control matching "' + action.target + '".';
          if (action.kind === 'click') { element.click(); return 'Clicked "' + label(element) + '".'; }
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

    private func adjustZoom(tabID: UUID, direction: Int) {
        guard let webView = webViews[tabID] else { return }
        let levels = Self.pageZoomLevels
        let currentIndex = levels.enumerated().min {
            abs($0.element - webView.pageZoom) < abs($1.element - webView.pageZoom)
        }?.offset ?? levels.firstIndex(of: 1) ?? 0
        let nextIndex = min(max(currentIndex + direction, 0), levels.count - 1)
        webView.pageZoom = levels[nextIndex]
    }

    // MARK: - Web View Hosting

    /// Hosts the active tab's web view inside a persistent container while
    /// keeping background tabs' web views parented (hidden) underneath it.
    /// Unparenting a web view tears down media presentation and throttles
    /// playback, so the floating mini player explicitly rehosts its tab.
    func hostActiveWebView(
        for tabID: UUID,
        in container: NSView,
        excludingTabIDs: Set<UUID>
    ) {
        guard let activeWebView = webViews[tabID] else { return }
        if miniPlayerHostedTabID == tabID {
            restoreMiniPlayerPresentation(tabID: tabID)
            miniPlayerHostedTabID = nil
        }

        for (id, webView) in webViews where id != tabID && !excludingTabIDs.contains(id) && id != miniPlayerHostedTabID {
            if keepsBackgroundWebViewParented(id) {
                guard webView.superview !== container else { continue }
                webView.frame = container.bounds
                webView.autoresizingMask = [.width, .height]
                webView.isHidden = true
                container.addSubview(webView, positioned: .below, relativeTo: nil)
            } else if webView.superview === container, webView.isHidden {
                // Idle background pages leave the hierarchy entirely so WebKit
                // can throttle their timers and rendering toward zero.
                webView.removeFromSuperview()
            }
        }

        guard hostedActiveTabID != tabID || activeWebView.superview !== container else { return }
        let previousActiveTabID = hostedActiveTabID
        hostedActiveTabID = tabID

        activeWebView.frame = container.bounds
        activeWebView.autoresizingMask = [.width, .height]
        activeWebView.isHidden = false
        activeWebView.removeFromSuperview()
        container.addSubview(activeWebView)

        if restoringTabIDs.contains(tabID), let snapshot = wakeSnapshots[tabID] {
            presentRestoreOverlay(snapshot, for: tabID, in: container)
        }

        // The outgoing web view stays visible (covered by the new active one)
        // for a beat so media keeps rendering while the mini player attaches.
        guard let previousActiveTabID, previousActiveTabID != tabID else { return }
        captureWakeSnapshot(for: previousActiveTabID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard
                let self,
                self.hostedActiveTabID != previousActiveTabID,
                // The mini player may have adopted this web view in the
                // meantime; hiding it would blank the floating player.
                self.miniPlayerHostedTabID != previousActiveTabID,
                let webView = self.webViews[previousActiveTabID],
                webView.superview != nil
            else {
                return
            }
            webView.isHidden = true
        }
    }

    func hostSplitWebView(
        for tabID: UUID,
        in container: NSView
    ) {
        guard let webView = webViews[tabID] else { return }
        if miniPlayerHostedTabID == tabID {
            restoreMiniPlayerPresentation(tabID: tabID)
            miniPlayerHostedTabID = nil
        }

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = false

        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)

        if restoringTabIDs.contains(tabID), let snapshot = wakeSnapshots[tabID] {
            presentRestoreOverlay(snapshot, for: tabID, in: container)
        }
    }

    func hostMiniPlayerWebView(for tabID: UUID, in container: NSView) {
        guard let webView = webViews[tabID] else { return }
        // Adopting a different tab must first restore the previously hosted
        // tab's page; otherwise that page is left stripped down to its video
        // element and shows a black shell when reopened from the sidebar.
        if let previousID = miniPlayerHostedTabID, previousID != tabID {
            detachMiniPlayerWebView(for: previousID)
        }
        coverActiveContainerWhileAdopting(webView)
        miniPlayerHostedTabID = tabID
        // Activate before shrinking the web view: media selection scores
        // element rects, and at mini player size no video can meet the
        // area thresholds — the page would keep its full layout (the X bug).
        activateMiniPlayerPresentation(tabID: tabID)
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = false

        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
    }

    func detachMiniPlayerWebView(for tabID: UUID) {
        guard miniPlayerHostedTabID == tabID else { return }
        restoreMiniPlayerPresentation(tabID: tabID)
        miniPlayerHostedTabID = nil
        webViews[tabID]?.isHidden = true
    }

    /// Summoning steals the page that was covering the content area before
    /// the incoming web view has painted, leaving a black void for a beat.
    /// Bridge it with the incoming tab's wake snapshot — the same cover a
    /// hibernation wake uses — released as soon as the page is up.
    private func coverActiveContainerWhileAdopting(_ stolenWebView: WKWebView) {
        guard
            let activeID = hostedActiveTabID,
            let activeWebView = webViews[activeID],
            activeWebView !== stolenWebView,
            let activeContainer = activeWebView.superview,
            stolenWebView.superview === activeContainer,
            restoreOverlays[activeID] == nil,
            let snapshot = wakeSnapshots[activeID]
        else { return }

        presentRestoreOverlay(snapshot, for: activeID, in: activeContainer)
        // Same beat the outgoing web view normally stays visible for after
        // a switch; the overlay then fades onto the painted page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.removeRestoreOverlay(for: activeID, animated: true)
        }
    }

    /// Starts the return-to-tab handoff: captures a freeze frame of the
    /// hosted web view for the floating player to morph with, then hands the
    /// page back and lays it out at the active container's full size while
    /// hidden — so the final swap reveals an already-settled page instead of
    /// the mini-sized layout flashing in the top-left corner.
    func prepareMiniPlayerReturn(for tabID: UUID, completion: @escaping (NSImage?) -> Void) {
        guard miniPlayerHostedTabID == tabID, let webView = webViews[tabID] else {
            completion(nil)
            return
        }

        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, self.miniPlayerHostedTabID == tabID else {
                completion(image)
                return
            }

            self.miniPlayerHostedTabID = nil
            webView.isHidden = true
            // Adopt the destination size before restoring so the page
            // relayouts (and restores its scroll position) at full layout.
            if
                let activeID = self.hostedActiveTabID,
                let activeFrame = self.webViews[activeID]?.frame,
                activeFrame.size != .zero
            {
                webView.frame = activeFrame
            }
            self.restoreMiniPlayerPresentation(tabID: tabID)
            completion(image)
        }
    }

    /// Unparenting tears down media presentation, so tabs with media stay
    /// parented (hidden); everything else is throttled by WebKit once removed.
    private func keepsBackgroundWebViewParented(_ tabID: UUID) -> Bool {
        store?.mediaStates[tabID] != nil
    }

    // MARK: - Tab Hibernation

    private func hibernateIdleWebViews() {
        guard let store else { return }
        let cutoff = Date().addingTimeInterval(-TabHibernationConfiguration.idleInterval)

        for tab in store.tabs where webViews[tab.id] != nil && isHibernatable(tab, idleBefore: cutoff) {
            hibernateIfNoUnsavedInput(tab.id)
        }
    }

    private func isHibernatable(_ tab: BrowserTab, idleBefore cutoff: Date) -> Bool {
        guard let store else { return false }
        return tab.id != store.activeTabID
            && !store.activeSplitGroupTabIDs.contains(tab.id)
            && tab.id != miniPlayerHostedTabID
            && tab.id != store.mediaControllerTabID
            && !tab.isPinned
            && !tab.isLoading
            && tab.url != nil
            && tab.lastAccessedAt < cutoff
            && store.mediaStates[tab.id] == nil
            && !popupTabIDsAwaitingFirstLoad.contains(tab.id)
            && !restoringTabIDs.contains(tab.id)
    }

    private func hibernateIfNoUnsavedInput(_ tabID: UUID, idleBefore cutoff: Date = Date()) {
        guard let webView = webViews[tabID] else { return }

        webView.evaluateJavaScript(Self.unsavedInputCheckScript) { [weak self] value, error in
            Task { @MainActor in
                guard error == nil, (value as? Bool) == false else { return }
                self?.hibernate(tabID, idleBefore: cutoff)
            }
        }
    }

    private func hibernate(_ tabID: UUID, idleBefore cutoff: Date = Date()) {
        guard
            let store,
            let webView = webViews[tabID],
            let tab = store.tabs.first(where: { $0.id == tabID }),
            // State may have changed while the unsaved-input check ran.
            isHibernatable(tab, idleBefore: cutoff)
        else { return }

        if let interactionState = webView.interactionState as? Data {
            hibernatedInteractionStates[tabID] = interactionState
        }
        removeWebView(for: tabID, keepingHibernationData: true)
    }

    /// Hibernation guard: anything the user may have typed keeps the page
    /// alive, because tearing down the web view would lose that input.
    private static let unsavedInputCheckScript = """
    (() => {
      const hasDirtyField = Array.from(document.querySelectorAll("input, textarea")).some((field) => {
        if (field.type === "checkbox" || field.type === "radio") {
          return field.checked !== field.defaultChecked;
        }
        if (["hidden", "submit", "button", "image", "reset"].includes(field.type)) {
          return false;
        }
        return field.value !== field.defaultValue;
      });
      if (hasDirtyField) { return true; }

      return Array.from(document.querySelectorAll("[contenteditable='true']"))
        .some((editor) => editor.textContent.trim().length > 0);
    })();
    """

    private static let readablePageTextScript = """
    (() => {
      const limit = 30000;
      const root = document.body;
      if (!root) { return ""; }

      const clone = root.cloneNode(true);
      clone.querySelectorAll([
        "script",
        "style",
        "noscript",
        "svg",
        "template",
        "canvas",
        "iframe",
        "[aria-hidden='true']"
      ].join(",")).forEach((node) => node.remove());

      clone.querySelectorAll("img").forEach((image) => {
        const label = [image.alt, image.title, image.getAttribute("aria-label")]
          .map((value) => String(value || "").trim())
          .find((value) => value.length > 0);
        if (label) {
          image.replaceWith(document.createTextNode(` Image: ${label} `));
        } else {
          image.remove();
        }
      });

      clone.querySelectorAll("input, textarea, select, button").forEach((control) => {
        const label = [
          control.getAttribute("aria-label"),
          control.placeholder,
          control.title,
          control.value,
          control.innerText,
          control.textContent
        ]
          .map((value) => String(value || "").trim())
          .find((value) => value.length > 0);
        if (label) {
          control.replaceWith(document.createTextNode(` ${control.tagName.toLowerCase()}: ${label} `));
        } else {
          control.remove();
        }
      });

      clone.querySelectorAll("a[href]").forEach((link) => {
        const label = String(link.innerText || link.textContent || link.getAttribute("aria-label") || link.href || "").trim();
        if (label) {
          link.replaceWith(document.createTextNode(` Link: ${label} `));
        } else {
          link.remove();
        }
      });

      const description = document.querySelector("meta[name='description']")?.content || "";
      const clean = (value) => String(value || "")
        .replace(/[\\s\\n\\r\\t]+/g, " ")
        .trim();
      const blockSelectors = [
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "p",
        "li",
        "dt",
        "dd",
        "figcaption",
        "caption",
        "th",
        "td",
        "[role='heading']",
        "[role='listitem']"
      ].join(",");
      const seenLines = new Set();
      const bodyLines = Array.from(clone.querySelectorAll(blockSelectors))
        .map((element) => clean(element.innerText || element.textContent))
        .filter((line) => {
          if (!line || seenLines.has(line)) { return false; }
          seenLines.add(line);
          return true;
        });

      const fallbackText = clean(clone.innerText || clone.textContent);
      const text = [
        document.title || "",
        description,
        bodyLines.length ? bodyLines.join("\\n") : fallbackText
      ]
        .join("\\n\\n")
        .replace(/[ \\t\\f\\v]+/g, " ")
        .replace(/\\n{3,}/g, "\\n\\n")
        .trim();

      return text.slice(0, limit);
    })();
    """

    private static let visiblePageControlsScript = """
    (() => {
      const selectors = [
        "a[href]",
        "button",
        "input",
        "textarea",
        "select",
        "[role='button']",
        "[role='link']",
        "[role='searchbox']",
        "[role='textbox']",
        "[role='combobox']"
      ].join(",");
      const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
      const seen = new Set();

      const clean = (value) => String(value || "")
        .replace(/[\\s\\n\\r\\t]+/g, " ")
        .trim();

      const labelFor = (element) => {
        const childImageText = Array.from(element.querySelectorAll("img"))
          .map((image) => clean([image.alt, image.title, image.getAttribute("aria-label")].find((candidate) => clean(candidate).length > 0)))
          .filter(Boolean)
          .join(" ");
        const ariaLabelledBy = clean(element.getAttribute("aria-labelledby"));
        const labelledByText = ariaLabelledBy
          .split(" ")
          .map((id) => clean(document.getElementById(id)?.innerText || document.getElementById(id)?.textContent))
          .filter(Boolean)
          .join(" ");
        const explicitLabel = element.id
          ? clean(document.querySelector(`label[for="${CSS.escape(element.id)}"]`)?.innerText)
          : "";
        const wrappingLabel = clean(element.closest("label")?.innerText);
        return clean([
          element.getAttribute("aria-label"),
          labelledByText,
          explicitLabel,
          wrappingLabel,
          element.placeholder,
          element.title,
          element.alt,
          childImageText,
          element.value,
          element.innerText,
          element.innerText || element.textContent,
          element.textContent
        ].find((candidate) => clean(candidate).length > 0));
      };

      const locationFor = (rect) => {
        const horizontal = rect.left < viewportWidth * 0.33
          ? "left"
          : rect.left > viewportWidth * 0.66 ? "right" : "center";
        const vertical = rect.top < viewportHeight * 0.33
          ? "top"
          : rect.top > viewportHeight * 0.66 ? "bottom" : "middle";
        return `${vertical} ${horizontal}`;
      };

      const rows = Array.from(document.querySelectorAll(selectors))
        .filter((element) => {
          if (!(element instanceof HTMLElement)) { return false; }
          if (element.closest("[aria-hidden='true'], [hidden]")) { return false; }
          const rect = element.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) { return false; }
          if (rect.bottom < 0 || rect.right < 0 || rect.top > viewportHeight || rect.left > viewportWidth) { return false; }
          const style = window.getComputedStyle(element);
          return style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || "1") > 0.05;
        })
        .map((element) => {
          const rect = element.getBoundingClientRect();
          const role = clean(element.getAttribute("role")) || element.tagName.toLowerCase();
          const label = labelFor(element);
          const href = element.href ? clean(element.href) : "";
          const type = clean(element.getAttribute("type"));
          const key = clean(`${role}|${type}|${label}|${href}|${Math.round(rect.top)}|${Math.round(rect.left)}`);
          if (seen.has(key)) { return null; }
          seen.add(key);
          if (!label && !href) { return null; }
          return `- ${role}${type ? ` (${type})` : ""}: ${label || href} [visible: ${locationFor(rect)}]${href ? ` [url: ${href}]` : ""}`;
        })
        .filter(Boolean)
        .slice(0, 80);

      return rows.length ? `Visible page controls and links:\\n${rows.join("\\n")}` : "";
    })();
    """

    // MARK: - Wake Snapshots & Restore Overlay

    private func captureWakeSnapshot(for tabID: UUID) {
        guard
            let webView = webViews[tabID],
            !webView.bounds.isEmpty,
            !webView.isHidden,
            webView.window != nil
        else { return }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(
            value: Double(min(webView.bounds.width, TabHibernationConfiguration.snapshotMaxWidth))
        )

        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, let image else { return }
                self.storeWakeSnapshot(image, for: tabID)
            }
        }
    }

    private func storeWakeSnapshot(_ image: NSImage, for tabID: UUID) {
        wakeSnapshots[tabID] = image
        guard wakeSnapshots.count > TabHibernationConfiguration.snapshotCacheLimit else { return }

        // Evict live tabs' snapshots first; hibernated tabs need theirs to
        // cover the wake-up reload.
        let evictableID = wakeSnapshots.keys.first { hibernatedInteractionStates[$0] == nil && $0 != tabID }
            ?? wakeSnapshots.keys.first { $0 != tabID }
        if let evictableID {
            wakeSnapshots[evictableID] = nil
        }
    }

    private func presentRestoreOverlay(_ snapshot: NSImage, for tabID: UUID, in container: NSView) {
        removeRestoreOverlay(for: tabID)

        let overlay = NSImageView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.image = snapshot
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.addSubview(overlay)
        restoreOverlays[tabID] = overlay

        // Failsafe: never leave a stale snapshot covering a live page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.removeRestoreOverlay(for: tabID, animated: true)
        }
    }

    private func scheduleRestoreOverlayRemoval(for tabID: UUID) {
        // Commit precedes first paint; hold the snapshot a beat longer so the
        // swap lands on rendered content instead of a flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.removeRestoreOverlay(for: tabID, animated: true)
        }
    }

    private func removeRestoreOverlay(for tabID: UUID, animated: Bool = false) {
        guard let overlay = restoreOverlays.removeValue(forKey: tabID) else { return }
        guard animated else {
            overlay.removeFromSuperview()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            // The completion handler is nonisolated in the SDK signature but
            // always runs on the main thread.
            MainActor.assumeIsolated {
                overlay.removeFromSuperview()
            }
        })
    }

    private func finishRestoreIfNeeded(for webView: WKWebView, failed: Bool = false) {
        guard let tabID = tabID(for: webView), restoringTabIDs.remove(tabID) != nil else { return }
        if failed {
            removeRestoreOverlay(for: tabID, animated: true)
        } else {
            scheduleRestoreOverlayRemoval(for: tabID)
        }
    }

    // MARK: - Content Blocking

    private func applyContentRuleList() async {
        guard contentRuleList == nil, let ruleList = await ContentBlockerService.shared.ruleList() else { return }
        contentRuleList = ruleList

        // Web views created before compilation finished pick the rules up
        // for their subsequent loads.
        for webView in webViews.values {
            webView.configuration.userContentController.add(ruleList)
        }
    }

    // MARK: - Media Playback State & Controls

    static let mediaStateMessageName = "candoaMediaState"

    /// Injected at document start; reports playback state for the selected
    /// foreground video candidate and ignores small/autoplay ad-like media.
    private static let mediaObserverScript = """
    (() => {
      if (window.__candoaMediaObserved) { return; }
      window.__candoaMediaObserved = true;

      const trustedMediaHosts = [
        "youtube.com",
        "youtu.be",
        "music.youtube.com",
        "vimeo.com",
        "twitch.tv",
        "netflix.com",
        "hulu.com",
        "max.com",
        "disneyplus.com",
        "primevideo.com",
        "apple.com",
        "tv.apple.com"
      ];
      const likelyAdPattern = /(^|[^a-z])(ad|ads|advert|advertisement|sponsor|sponsored|promo|preroll|midroll|postroll|ima|doubleclick|outstream|instream|teads|taboola|outbrain|aniview|primis|spotx|yieldmo|adchoices|google_ads|gpt)([^a-z]|$)/i;
      const likelyPreviewPattern = /(^|[^a-z])(hover|thumbnail|preview|previews|inline-preview|video-preview|moving-thumbnail|ytp-inline-preview)([^a-z]|$)/i;
      const miniPlayerClass = "__candoa-mini-player-active";
      const miniPlayerAttr = "data-candoa-mini-player";
      const miniPlayerHostID = "__candoa-mini-player-host";
      const miniPlayerStyleID = "__candoa-mini-player-style";

      const normalizedHostname = () => location.hostname.toLowerCase().replace(/^www[.]/, "");

      const isTrustedMediaHost = () => {
        const hostname = normalizedHostname();
        return trustedMediaHosts.some((host) => hostname === host || hostname.endsWith("." + host));
      };

      const isYouTubeHost = () => {
        const hostname = normalizedHostname();
        return hostname === "youtube.com" || hostname.endsWith(".youtube.com") || hostname === "youtu.be";
      };

      const isYouTubePlaybackPage = () => {
        if (normalizedHostname() === "music.youtube.com") { return true; }

        const pathname = location.pathname;
        return pathname === "/watch" ||
          pathname.startsWith("/shorts/") ||
          pathname.startsWith("/live/") ||
          pathname.startsWith("/embed/");
      };

      const finiteDuration = (media) => Number.isFinite(media.duration) ? media.duration : 0;

      const elementIdentity = (element) => {
        const parts = [];
        let cursor = element;
        for (let depth = 0; cursor && depth < 7; depth += 1, cursor = cursor.parentElement) {
          const className = typeof cursor.className === "string"
            ? cursor.className
            : (cursor.getAttribute("class") || "");
          parts.push(
            cursor.id || "",
            className,
            cursor.getAttribute("aria-label") || "",
            cursor.getAttribute("data-testid") || "",
            cursor.getAttribute("role") || "",
            cursor.getAttribute("src") || ""
          );
        }
        parts.push(element.currentSrc || element.src || "");
        return parts.join(" ").toLowerCase();
      };

      const looksLikeAd = (media) => likelyAdPattern.test(elementIdentity(media));

      const looksLikeTransientPreview = (media) => {
        const muted = media.muted || media.volume === 0;
        if (!muted) { return false; }

        if (isYouTubeHost() && !isYouTubePlaybackPage()) { return true; }

        return likelyPreviewPattern.test(elementIdentity(media));
      };

      const visibleRect = (media) => {
        const rect = media.getBoundingClientRect();
        const style = window.getComputedStyle(media);
        const opacity = Number.parseFloat(style.opacity || "1");
        if (
          style.display === "none" ||
          style.visibility === "hidden" ||
          opacity === 0 ||
          rect.width <= 0 ||
          rect.height <= 0
        ) {
          return { width: 0, height: 0, area: 0 };
        }

        return {
          width: rect.width,
          height: rect.height,
          area: rect.width * rect.height
        };
      };

      const mediaScore = (media) => {
        if (media.tagName?.toLowerCase() !== "video") { return -1; }
        if (media.ended) { return -1; }

        const trustedHost = isTrustedMediaHost();
        if (!trustedHost && looksLikeAd(media)) { return -1; }

        const isPlaying = !media.paused && !media.ended && media.readyState >= 2;
        const hasProgress = media.currentTime > 0 && !media.ended;
        if (!isPlaying && !hasProgress && media.readyState < 2) { return -1; }

        const isMiniPlayerPresentation = document.documentElement.classList.contains(miniPlayerClass);
        if (!isMiniPlayerPresentation && looksLikeTransientPreview(media)) { return -1; }

        const rect = visibleRect(media);
        const viewportArea = Math.max(window.innerWidth * window.innerHeight, 1);
        const prominentDimensions = (rect.width >= 360 && rect.height >= 200) ||
          (rect.width >= 240 && rect.height >= 360);
        const fillsEnoughSpace = isMiniPlayerPresentation
          ? rect.area / viewportArea >= 0.60
          : prominentDimensions && rect.area >= 120000 && rect.area / viewportArea >= 0.08;
        const duration = finiteDuration(media);
        const longEnough = duration >= 45;
        const audible = !(media.muted || media.volume === 0);

        if (!fillsEnoughSpace) { return -1; }
        if (!trustedHost && (!longEnough || !audible)) { return -1; }

        return (isPlaying ? 1000000 : 0) + rect.area + Math.min(duration, 7200);
      };

      const selectMedia = () => Array.from(document.querySelectorAll("video"))
        .map((media) => ({ media, score: mediaScore(media) }))
        .filter((candidate) => candidate.score >= 0)
        .sort((a, b) => b.score - a.score)[0]?.media || null;

      const clearMiniPlayerMarkers = () => {
        document.querySelectorAll("[" + miniPlayerAttr + "]").forEach((element) => {
          element.removeAttribute(miniPlayerAttr);
        });
      };

      const ensureMiniPlayerHost = () => {
        let host = document.getElementById(miniPlayerHostID);
        if (host) { return host; }

        host = document.createElement("div");
        host.id = miniPlayerHostID;
        (document.body || document.documentElement).appendChild(host);
        return host;
      };

      const restoreMiniPlayerMedia = () => {
        const state = window.__candoaMiniPlayerState;
        if (!state?.media) { return; }

        state.media.removeAttribute(miniPlayerAttr);

        if (state.parent?.isConnected) {
          if (state.placeholder?.parentNode === state.parent) {
            state.parent.insertBefore(state.media, state.placeholder);
            state.placeholder.remove();
          } else if (state.nextSibling?.parentNode === state.parent) {
            state.parent.insertBefore(state.media, state.nextSibling);
          } else {
            state.parent.appendChild(state.media);
          }
        }

        delete window.__candoaMiniPlayerState;

        // Collapsing the page to the video zeroed the scroll position; put
        // it back so the page returns exactly where the user left it.
        if (Number.isFinite(state.scrollX) && Number.isFinite(state.scrollY)) {
          window.scrollTo(state.scrollX, state.scrollY);
        }
      };

      const installMiniPlayerStyle = () => {
        if (document.getElementById(miniPlayerStyleID)) { return; }
        const style = document.createElement("style");
        style.id = miniPlayerStyleID;
        style.textContent = [
          "html." + miniPlayerClass + ", html." + miniPlayerClass + " body { background: #000 !important; margin: 0 !important; width: 100% !important; height: 100% !important; overflow: hidden !important; }",
          "html." + miniPlayerClass + " body > :not(#" + miniPlayerHostID + ") { display: none !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " { display: flex !important; position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; align-items: center !important; justify-content: center !important; overflow: hidden !important; z-index: 2147483647 !important; visibility: visible !important; background: #000 !important; pointer-events: none !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " * { visibility: visible !important; }",
          "html." + miniPlayerClass + " #" + miniPlayerHostID + " video[" + miniPlayerAttr + "='true'] { display: block !important; position: static !important; width: 100vw !important; height: 100vh !important; max-width: 100vw !important; max-height: 100vh !important; min-width: 0 !important; min-height: 0 !important; object-fit: contain !important; opacity: 1 !important; background: #000 !important; transform: none !important; border-radius: 0 !important; box-shadow: none !important; pointer-events: none !important; }"
        ].join("");
        document.documentElement.appendChild(style);
      };

      // Last media that passed full-layout selection. Activation may run
      // after the web view has shrunk to mini player size, where nothing
      // can satisfy the area thresholds — this remembers the right element.
      let lastEligibleMedia = null;

      window.__candoaSelectMedia = selectMedia;
      window.__candoaActivateMiniPlayerPresentation = () => {
        const existingState = window.__candoaMiniPlayerState;
        if (
          existingState?.media?.isConnected &&
          existingState.media.parentElement?.id === miniPlayerHostID
        ) {
          document.documentElement.classList.add(miniPlayerClass);
          existingState.media.setAttribute(miniPlayerAttr, "true");
          return true;
        }

        const fallback = lastEligibleMedia?.isConnected && !lastEligibleMedia.ended
          ? lastEligibleMedia
          : null;
        const media = selectMedia() || fallback;
        if (!media) { return false; }

        installMiniPlayerStyle();
        clearMiniPlayerMarkers();
        const host = ensureMiniPlayerHost();
        const placeholder = document.createComment("Candoa mini player media placeholder");
        const parent = media.parentNode;
        const nextSibling = media.nextSibling;

        if (parent) {
          parent.insertBefore(placeholder, media);
        }

        window.__candoaMiniPlayerState = {
          media,
          parent,
          nextSibling,
          placeholder,
          scrollX: window.scrollX,
          scrollY: window.scrollY
        };

        document.documentElement.classList.add(miniPlayerClass);
        media.setAttribute(miniPlayerAttr, "true");
        host.appendChild(media);

        return true;
      };

      window.__candoaDeactivateMiniPlayerPresentation = () => {
        document.documentElement.classList.remove(miniPlayerClass);
        restoreMiniPlayerMedia();
        clearMiniPlayerMarkers();
        document.getElementById(miniPlayerHostID)?.remove();
        window.__candoaReportMediaState?.();
      };

      let playbackTicker = null;
      const syncPlaybackTicker = (isPlaying) => {
        if (isPlaying && playbackTicker === null) {
          playbackTicker = window.setInterval(() => report(), 1000);
        } else if (!isPlaying && playbackTicker !== null) {
          window.clearInterval(playbackTicker);
          playbackTicker = null;
        }
      };

      const report = () => {
        const current = selectMedia();
        if (current) { lastEligibleMedia = current; }
        const playing = current && !current.paused && !current.ended && current.readyState >= 2;
        syncPlaybackTicker(Boolean(playing));

        const handler = window.webkit?.messageHandlers?.\(mediaStateMessageName);
        if (!handler) { return; }
        // The on-page rect only means anything while the page has its real
        // layout; once the mini player presentation strips the page, the
        // video fills the (tiny) viewport and the rect would be garbage.
        const presentationActive = document.documentElement.classList.contains(miniPlayerClass);
        const pageRect = current && !presentationActive ? current.getBoundingClientRect() : null;
        handler.postMessage({
          hasMedia: Boolean(current),
          isPlaying: Boolean(playing),
          isMuted: current ? (current.muted || current.volume === 0) : false,
          isMiniPlayerEligible: Boolean(current),
          currentTime: current ? current.currentTime : 0,
          duration: current ? finiteDuration(current) : 0,
          videoRect: pageRect
            ? { x: pageRect.x, y: pageRect.y, width: pageRect.width, height: pageRect.height }
            : null
        });
      };
      window.__candoaReportMediaState = report;

      let reportQueued = false;
      const queueReport = () => {
        if (reportQueued) { return; }
        reportQueued = true;
        window.setTimeout(() => {
          reportQueued = false;
          report();
        }, 250);
      };

      // Event-driven with a coalescing timeout. The only steady timer is the
      // 1 Hz progress ticker, and it exists solely while media is playing —
      // an idle page costs nothing.
      ["play", "playing", "pause", "ended", "emptied", "seeked", "volumechange", "loadedmetadata", "loadeddata"].forEach((eventName) => {
        document.addEventListener(eventName, queueReport, true);
      });
      document.addEventListener("visibilitychange", queueReport);
      window.setTimeout(report, 0);
    })();
    """

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == Self.mediaStateMessageName,
            let webView = message.webView,
            let tabID = tabID(for: webView),
            let body = message.body as? [String: Any]
        else {
            return
        }

        let state = TabMediaState(
            hasMedia: body["hasMedia"] as? Bool ?? false,
            isPlaying: body["isPlaying"] as? Bool ?? false,
            isMuted: body["isMuted"] as? Bool ?? false,
            isMiniPlayerEligible: body["isMiniPlayerEligible"] as? Bool ?? false,
            currentTime: body["currentTime"] as? Double ?? 0,
            duration: body["duration"] as? Double ?? 0,
            pageVideoFrame: Self.videoFrame(from: body["videoRect"])
        )
        store?.updateMediaState(tabID: tabID, state: state)
    }

    private static func videoFrame(from value: Any?) -> CGRect? {
        guard
            let rect = value as? [String: Any],
            let x = rect["x"] as? Double,
            let y = rect["y"] as? Double,
            let width = rect["width"] as? Double,
            let height = rect["height"] as? Double,
            width > 0, height > 0,
            [x, y, width, height].allSatisfy(\.isFinite)
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func activateMiniPlayerPresentation(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.__candoaActivateMiniPlayerPresentation?.()")
    }

    private func restoreMiniPlayerPresentation(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.__candoaDeactivateMiniPlayerPresentation?.()")
    }

    func toggleMediaPlayback(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = selected ? [selected] : Array.from(document.querySelectorAll("video, audio"));
          const playing = medias.filter((media) => !media.paused && !media.ended);
          if (playing.length > 0) {
            playing.forEach((media) => media.pause());
            return;
          }

          const resumable = medias.find((media) => media.currentTime > 0 && !media.ended)
            || medias.find((media) => media.readyState >= 2);
          if (resumable) { resumable.play(); }
        })();
        """)
    }

    func pauseMediaPlayback(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = selected ? [selected] : Array.from(document.querySelectorAll("video, audio"));
          medias
            .filter((media) => !media.paused && !media.ended)
            .forEach((media) => media.pause());
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func toggleMediaMute(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const selected = window.__candoaSelectMedia?.();
          const medias = (selected ? [selected] : Array.from(document.querySelectorAll("video, audio")))
            .filter((media) => media.readyState >= 1 || media.currentTime > 0);
          if (medias.length === 0) { return; }

          const shouldMute = medias.some((media) => !media.muted);
          medias.forEach((media) => { media.muted = shouldMute; });
        })();
        """)
    }

    func skipMediaTrack(tabID: UUID, forward: Bool) {
        let buttonSelectors = forward
            ? ".ytp-next-button, [aria-label='Next'], [data-testid='control-button-skip-forward']"
            : ".ytp-prev-button, [aria-label='Previous'], [data-testid='control-button-skip-back']"
        let seekDelta = forward ? 15.0 : -15.0

        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const button = document.querySelector("\(buttonSelectors)");
          if (button) {
            button.click();
            return;
          }

          // No track controls on this page: nudge the timeline instead.
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = media.currentTime + (\(seekDelta));
          media.currentTime = Math.max(0, Number.isFinite(media.duration) ? Math.min(media.duration, target) : target);
        })();
        """)
    }

    func seekMedia(tabID: UUID, by seconds: Double) {
        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = media.currentTime + (\(seconds));
          media.currentTime = Math.max(0, Number.isFinite(media.duration) ? Math.min(media.duration, target) : target);
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func seekMedia(tabID: UUID, to time: Double) {
        let targetTime = max(0, time)

        webViews[tabID]?.evaluateJavaScript("""
        (() => {
          const media = window.__candoaSelectMedia?.()
            || Array.from(document.querySelectorAll("video, audio"))
            .find((candidate) => !candidate.paused && !candidate.ended)
            || Array.from(document.querySelectorAll("video, audio")).find((candidate) => candidate.currentTime > 0);
          if (!media) { return; }

          const target = \(targetTime);
          media.currentTime = Number.isFinite(media.duration) ? Math.min(media.duration, target) : target;
          window.__candoaReportMediaState?.();
        })();
        """)
    }

    func refreshMediaState(tabID: UUID) {
        webViews[tabID]?.evaluateJavaScript("window.__candoaReportMediaState?.()")
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateStore(from: webView, isLoading: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        finishRestoreIfNeeded(for: webView)
        updateStore(from: webView, isLoading: webView.isLoading)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateStore(from: webView, isLoading: false)
        recordHistoryVisit(for: webView)
        refreshFavicon(for: webView)
        forwardWebAppPromptIfNeeded(for: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishRestoreIfNeeded(for: webView, failed: true)
        updateStore(from: webView, isLoading: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishRestoreIfNeeded(for: webView, failed: true)
        updateStore(from: webView, isLoading: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateStore(from: webView, isLoading: false)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        configureDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        configureDownload(download)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let store else { return nil }

        let sourceSpaceID = tabID(for: webView)
            .flatMap { sourceTabID in store.tabs.first { $0.id == sourceTabID }?.spaceID }
            ?? store.activeSpaceID
        let popupTab = store.createPopupTab(url: navigationAction.request.url, in: sourceSpaceID)

        // WebKit drives the popup's first navigation through the returned web view,
        // which must be created with the configuration it hands us.
        let popupWebView = WKWebView(frame: .zero, configuration: configuration)
        register(popupWebView, for: popupTab.id)
        popupTabIDsAwaitingFirstLoad.insert(popupTab.id)
        return popupWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tabID = tabID(for: webView) else { return }
        store?.closeTab(tabID)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = javaScriptPanelAlert(message: message, frame: frame)
        _ = await presentPanel(alert, for: webView)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = javaScriptPanelAlert(message: message, frame: frame)
        alert.addButton(withTitle: "Cancel")
        return await presentPanel(alert, for: webView) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = javaScriptPanelAlert(message: prompt, frame: frame)
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        inputField.stringValue = defaultText ?? ""
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = await presentPanel(alert, for: webView)
        return response == .alertFirstButtonReturn ? inputField.stringValue : nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }

        return response == .OK ? panel.urls : nil
    }

    private func javaScriptPanelAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    private func presentPanel(_ alert: NSAlert, for webView: WKWebView) async -> NSApplication.ModalResponse {
        if let window = webView.window {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }

    // MARK: - Downloads

    private func configureDownload(_ download: WKDownload) {
        download.delegate = self
        activeDownloads.insert(download)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }

        let destination = Self.uniqueDestination(for: suggestedFilename, in: downloadsDirectory)
        downloadDestinations[download] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.remove(download)
        guard let destination = downloadDestinations.removeValue(forKey: download) else { return }

        // Bounces the Downloads stack in the Dock, matching native browser behavior.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"),
            object: destination.path,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.remove(download)
        downloadDestinations[download] = nil
    }

    private static func uniqueDestination(for suggestedFilename: String, in directory: URL) -> URL {
        let baseName = (suggestedFilename as NSString).deletingPathExtension
        let fileExtension = (suggestedFilename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(suggestedFilename)
        var attempt = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let numberedName = fileExtension.isEmpty
                ? "\(baseName) \(attempt)"
                : "\(baseName) \(attempt).\(fileExtension)"
            candidate = directory.appendingPathComponent(numberedName)
            attempt += 1
        }

        return candidate
    }

    private func tabID(for webView: WKWebView) -> UUID? {
        guard let tabIDString = tabIDsByWebView.object(forKey: webView) as String? else { return nil }
        return UUID(uuidString: tabIDString)
    }

    private func updateStore(from webView: WKWebView, isLoading: Bool) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        if webView.url != nil {
            popupTabIDsAwaitingFirstLoad.remove(tabID)
        }

        let progress = webView.estimatedProgress
        let resolvedIsLoading = isLoading && progress < 0.999

        store?.updateTabFromWebView(
            tabID: tabID,
            title: webView.title,
            url: webView.url,
            isLoading: resolvedIsLoading,
            loadingProgress: resolvedIsLoading ? progress : 1,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward
        )
    }

    private func recordHistoryVisit(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        store?.recordHistoryVisit(tabID: tabID, title: webView.title, url: webView.url)
    }

    private func observe(_ webView: WKWebView, tabID: UUID) {
        observations[tabID] = [
            webView.observe(\.title, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor in
                    guard let webView else { return }
                    self?.updateStore(from: webView, isLoading: webView.isLoading)
                }
            }
        ]
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func refreshFavicon(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString)
        else {
            return
        }

        let script = """
        (() => {
          const links = Array.from(document.querySelectorAll("link[rel*='icon'], link[rel='mask-icon']"));
          const first = links.map(link => link.href).find(Boolean);
          return first || "";
        })();
        """

        webView.evaluateJavaScript(script) { [weak self, weak webView] value, _ in
            Task { @MainActor in
                guard let self, let webView else { return }
                let candidateString = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateURL = candidateString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
                let data = await FaviconService.shared.faviconData(for: webView.url, candidateURL: candidateURL)
                self.store?.updateFavicon(tabID: tabID, data: data)
            }
        }
    }

    private func forwardWebAppPromptIfNeeded(for webView: WKWebView) {
        guard
            let tabIDString = tabIDsByWebView.object(forKey: webView) as String?,
            let tabID = UUID(uuidString: tabIDString),
            let pendingPrompt = pendingWebAppPrompts[tabID],
            store?.navigationService.canForwardWebAppPrompt(to: webView.url, providerID: pendingPrompt.providerID) == true
        else {
            return
        }

        let promptLiteral = javaScriptStringLiteral(for: pendingPrompt.query)
        let script = """
        (() => {
          const prompt = \(promptLiteral);
          const selectors = [
            "textarea",
            "[contenteditable='true']",
            "[role='textbox']"
          ];

          const isVisible = (element) => {
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          };

          const setPlainInputValue = (element, value) => {
            const prototype = Object.getPrototypeOf(element);
            const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
            if (descriptor && descriptor.set) {
              descriptor.set.call(element, value);
            } else {
              element.value = value;
            }
          };

          const setPromptText = (element) => {
            element.focus();
            if (element.isContentEditable) {
              const selection = window.getSelection();
              const range = document.createRange();
              range.selectNodeContents(element);
              selection.removeAllRanges();
              selection.addRange(range);
              document.execCommand("insertText", false, prompt);
            } else {
              setPlainInputValue(element, prompt);
            }

            element.dispatchEvent(new InputEvent("input", {
              bubbles: true,
              cancelable: true,
              data: prompt,
              inputType: "insertText"
            }));
            element.dispatchEvent(new Event("change", { bubbles: true }));
          };

          const submitPrompt = (element) => {
            const buttons = Array.from(document.querySelectorAll("button, [role='button']"));
            const sendButton = buttons.find((button) => {
              const label = [
                button.getAttribute("aria-label"),
                button.getAttribute("data-tooltip"),
                button.title,
                button.textContent
              ].filter(Boolean).join(" ").toLowerCase();
              return !button.disabled && !button.getAttribute("aria-disabled") && /send|submit/.test(label);
            });

            if (sendButton) {
              sendButton.click();
              return;
            }

            element.dispatchEvent(new KeyboardEvent("keydown", {
              bubbles: true,
              cancelable: true,
              key: "Enter",
              code: "Enter"
            }));
          };

          const findPromptBox = () => {
            return selectors
              .flatMap((selector) => Array.from(document.querySelectorAll(selector)))
              .filter(isVisible)
              .find((element) => !element.closest("[aria-hidden='true']"));
          };

          const deadline = Date.now() + 10000;
          return new Promise((resolve) => {
            const attempt = () => {
              const promptBox = findPromptBox();
              if (!promptBox) {
                if (Date.now() < deadline) {
                  window.setTimeout(attempt, 250);
                } else {
                  resolve(false);
                }
                return;
              }

              setPromptText(promptBox);
              window.setTimeout(() => {
                submitPrompt(promptBox);
                resolve(true);
              }, 200);
            };

            attempt();
          });
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] value, error in
            Task { @MainActor in
                self?.pendingWebAppPrompts[tabID] = nil
            }
        }
    }

    private func javaScriptStringLiteral(for value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let arrayLiteral = String(data: data, encoding: .utf8),
            arrayLiteral.first == "[",
            arrayLiteral.last == "]"
        else {
            return "\"\""
        }

        return String(arrayLiteral.dropFirst().dropLast())
    }

}

// In an extension to avoid a spurious near-match warning against the
// deprecated decideMediaCapturePermissionsFor requirement.
extension WebViewCoordinator {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        await requestSiteMediaCapturePermission(for: origin, type: type, webView: webView)
    }

    private func requestSiteMediaCapturePermission(
        for origin: WKSecurityOrigin,
        type: WKMediaCaptureType,
        webView: WKWebView
    ) async -> WKPermissionDecision {
        let host = origin.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = host.isEmpty ? "This website" : host
        let mediaName = mediaCaptureDisplayName(for: type)

        let alert = NSAlert()
        alert.messageText = "\(siteName) wants to use \(mediaName)"
        alert.informativeText = "Allow access only if you trust this page."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")

        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        return response == .alertFirstButtonReturn ? .grant : .deny
    }

    private func mediaCaptureDisplayName(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera:
            return "your camera"
        case .microphone:
            return "your microphone"
        case .cameraAndMicrophone:
            return "your camera and microphone"
        @unknown default:
            return "media capture"
        }
    }
}
