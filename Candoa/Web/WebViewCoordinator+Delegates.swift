import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The page is going away; its hovered-link pill must not outlive it,
        // and neither may its reader overlay or probe verdict.
        if let tabID = tabID(for: webView) {
            store?.updateHoveredLink(tabID: tabID, href: nil)
            clearReaderState(for: tabID)
            // This tab is moving; whatever the last finished page was, it is
            // no longer parked anywhere.
            signInRedirectCheckTokens[tabID] = nil
        }
        updateStore(from: webView, isLoading: true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        finishRestoreIfNeeded(for: webView)
        // A committing page is the last beat of the open-a-tab flow, after the
        // command palette has unmounted and released the window's focus — the
        // earlier attempt during hosting gets clobbered by that unmount.
        focusActiveWebViewIfIdle()
        // Real content is arriving; any recovery cover comes down now, not
        // at load start, so the error stays readable through a failed retry.
        if let tabID = tabID(for: webView) {
            store?.clearLoadFailure(tabID: tabID)
            // The old page's frames are gone, and any draft they held with
            // them; the hibernation pin does not outlive the document.
            userEditedTabIDs.remove(tabID)
            // The committed page's notification shim starts at "default";
            // this corrects it to the origin's stored decision.
            pushNotificationPermissionState(to: webView)
            // A committed page ends the download-conversion quarantine.
            downloadConvertedTabIDs.remove(tabID)
            // …and the failed-destination one: this tab is loading again.
            failedProvisionalURLs[tabID] = nil
        }
        clearCrossOriginPageThemeColor(for: webView)
        updateStore(from: webView, isLoading: webView.isLoading)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateStore(from: webView, isLoading: false)
        if let tabID = tabID(for: webView) {
            probeReaderAvailabilityIfNeeded(for: tabID)
        }
        recordHistoryVisit(for: webView)
        checkForEmptySignInRedirect(in: webView)
        refreshFavicon(for: webView)
        armPageThemeColorRetries(for: webView)
        refreshPageThemeColor(for: webView)
        forwardWebAppPromptIfNeeded(for: webView)
        reportWebsiteAppearanceForUITesting(from: webView)
        dockWebInspectorForUITestingIfNeeded(from: webView)
    }

    // MARK: - Stranded Sign-In Redirects

    /// A sign-in redirect page's whole job is to read the response in its URL,
    /// finish the handshake, and send the person back where they started. When
    /// that fails — the handshake state is gone, its opener has closed, the
    /// code is already spent — the page has no content of its own and the tab
    /// is left showing nothing, with the dead URL persisted so every relaunch
    /// restores the same blank page. Nothing on screen says what happened or
    /// offers a way out, so this puts the recovery cover over it.
    func checkForEmptySignInRedirect(in webView: WKWebView) {
        guard
            let tabID = tabID(for: webView),
            let url = webView.url,
            TabLoadFailure.carriesSignInResponse(url)
        else {
            return
        }

        let token = UUID()
        signInRedirectCheckTokens[tabID] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + SignInRedirectConfiguration.deadEndGrace) {
            [weak self, weak webView] in
            guard
                let self,
                let webView,
                self.signInRedirectCheckTokens[tabID] == token
            else {
                return
            }
            self.reportSignInRedirectIfStranded(tabID: tabID, url: url, webView: webView, token: token)
        }
    }

    private func reportSignInRedirectIfStranded(
        tabID: UUID,
        url: URL,
        webView: WKWebView,
        token: UUID
    ) {
        // Still sitting on the very same response URL, done loading. A page
        // that completed its handshake has navigated away by now.
        guard webView.url == url, !webView.isLoading else { return }

        webView.evaluateJavaScript("document.body ? document.body.innerText.trim().length : 0") {
            [weak self] value, error in
            Task { @MainActor in
                guard
                    let self,
                    error == nil,
                    let renderedCharacters = value as? Int,
                    renderedCharacters == 0,
                    // Nothing raced past us while the page answered.
                    self.signInRedirectCheckTokens[tabID] == token,
                    self.webViews[tabID] === webView,
                    webView.url == url
                else {
                    return
                }
                self.signInRedirectCheckTokens[tabID] = nil
                self.store?.reportStrandedSignInRedirect(tabID: tabID, url: url)
            }
        }
    }

    /// Puts a UI test in the docked-inspector state. WebKit only docks from
    /// the inspector's own chrome, which no test can reach, and its docked
    /// placement is the thing under test.
    func dockWebInspectorForUITestingIfNeeded(from webView: WKWebView) {
        guard
            BrowserStore.isUITesting,
            ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_DOCK_INSPECTOR"] == "1",
            let tabID = tabID(for: webView),
            tabID == hostedActiveTabID,
            !isWebInspectorVisible(for: tabID)
        else {
            return
        }

        showWebInspector(for: tabID)
        dockWebInspectorForUITesting(tabID: tabID, attemptsLeft: 12)
    }

    /// WebKit refuses to dock until the inspector's own frontend page is up,
    /// and says so only by doing nothing, so this keeps asking for a few
    /// seconds and stops as soon as the inspector lands in the pane's lane.
    private func dockWebInspectorForUITesting(tabID: UUID, attemptsLeft: Int) {
        attachWebInspector(for: tabID)
        reportInspectorPlacementForUITesting(for: tabID)

        guard
            attemptsLeft > 1,
            !uiTestingAttachedInspectorDescription(for: tabID).hasPrefix("attached")
        else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dockWebInspectorForUITesting(tabID: tabID, attemptsLeft: attemptsLeft - 1)
        }
    }

    func reportWebsiteAppearanceForUITesting(from webView: WKWebView) {
        guard BrowserStore.isUITesting else { return }
        webView.evaluateJavaScript(
            "[window.__candoaInitialDark === true, matchMedia('(prefers-color-scheme: dark)').matches, "
                + "document.documentElement.hasAttribute('dark')]"
        ) { [weak self] result, _ in
            guard let values = result as? [Bool], values.count == 3 else { return }
            Task { @MainActor [weak self] in
                self?.store?.uiTestingWebsiteAppearanceDescription =
                    "initial-\(values[0] ? "dark" : "light")-media-\(values[1] ? "dark" : "light")-"
                    + "html-\(values[2] ? "dark" : "light")"
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishRestoreIfNeeded(for: webView, failed: true)
        reportNavigationFailure(for: webView, error: error)
        updateStore(from: webView, isLoading: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishRestoreIfNeeded(for: webView, failed: true)
        // Quarantine before the failure is published: publishing schedules the
        // SwiftUI pass that would otherwise re-request this destination.
        quarantineFailedDestination(for: webView, error: error)
        reportNavigationFailure(for: webView, error: error)
        updateStore(from: webView, isLoading: false)
    }

    /// Records the destination the tab is pointed at so ensureLoaded stops
    /// re-requesting it (see `failedProvisionalURLs`). Only failures that
    /// surface recovery UI count: a cancelled load is ordinary browsing —
    /// usually one navigation superseding another — and quarantining there
    /// would strand the successor that is still in flight.
    private func quarantineFailedDestination(for webView: WKWebView, error: Error) {
        guard TabLoadFailure.make(from: error as NSError, failedURL: nil) != nil else { return }
        guard
            let tabID = tabID(for: webView),
            let destination = store?.tabs.first(where: { $0.id == tabID })?.url
        else { return }
        failedProvisionalURLs[tabID] = destination
    }

    private func reportNavigationFailure(for webView: WKWebView, error: Error) {
        guard let tabID = tabID(for: webView) else { return }
        let nsError = error as NSError
        let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        store?.reportLoadFailure(tabID: tabID, error: nsError, failedURL: failedURL)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateStore(from: webView, isLoading: false)
        guard let store, let tabID = tabID(for: webView) else { return }

        let now = Date()
        let isRepeatCrash = webContentTerminationDates[tabID]
            .map { now.timeIntervalSince($0) < 60 } ?? false
        webContentTerminationDates[tabID] = now
        let isVisible = store.activeTabID == tabID
            || store.displayedSplitTabIDs.contains(tabID)

        // The tab itself is never touched — only its web content recovers.
        // A visible tab's first crash reloads in place; repeat crashes (or a
        // background tab's) surface the recovery state instead, so a broken
        // page can't reload-loop.
        if isVisible, !isRepeatCrash {
            webView.reload()
        } else {
            store.reportWebContentTermination(tabID: tabID)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }

        // Safari's ⌘-click: the link opens in a new background tab and the
        // current page keeps the screen; ⇧ added makes the new tab active.
        // Intercepting here (not createWebViewWith) also catches modified
        // clicks on target=_blank links, which would otherwise become
        // foreground popups. Non-web schemes (mailto:, javascript:) keep
        // their plain-click meaning — a new tab could not load them.
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https",
           let store {
            store.openLinkInNewTab(
                url: url,
                from: tabID(for: webView),
                activate: navigationAction.modifierFlags.contains(.shift)
            )
            return .cancel
        }

        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        configureDownload(download)
        realignTabAfterDownloadConversion(for: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        configureDownload(download)
        realignTabAfterDownloadConversion(for: webView)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let store else { return nil }

        // A Site Info "Block" decision for the source page's origin stops the
        // pop-up before any tab or web view exists. Returning nil is the
        // supported refusal; WebKit reports it to the page as a blocked open.
        if let sourceURL = webView.url,
           SitePermissionConfiguration.decision(for: .popupWindows, url: sourceURL) == .deny {
            if BrowserStore.isUITesting {
                store.uiTestingPopupDiagnostics.append(
                    "blocked href=\(navigationAction.request.url?.absoluteString.prefix(80) ?? "nil")"
                )
            }
            return nil
        }

        let sourceSpaceID = tabID(for: webView)
            .flatMap { sourceTabID in store.tabs.first { $0.id == sourceTabID }?.spaceID }
            ?? store.activeSpaceID
        // Sites that route clicks through window.open still honor the
        // ⌘-click contract from decidePolicyFor: the tab loads in the
        // background, ⇧ added makes it active. Unmodified window.open
        // (real pop-ups, OAuth windows) keeps taking the screen.
        let modifiers = navigationAction.modifierFlags
        let activates = !modifiers.contains(.command) || modifiers.contains(.shift)
        if BrowserStore.isUITesting, !activates {
            store.uiTestingPopupDiagnostics.append(
                "background href=\(navigationAction.request.url?.absoluteString.prefix(80) ?? "nil")"
            )
        }
        let popupTab = store.createPopupTab(
            url: navigationAction.request.url,
            in: sourceSpaceID,
            activate: activates
        )

        // WebKit drives the popup's first navigation through the returned web view,
        // which must be created with the configuration it hands us.
        let popupWebView = BrowserWebView(frame: .zero, configuration: configuration)
        register(popupWebView, for: popupTab.id)
        popupTabIDsAwaitingFirstLoad.insert(popupTab.id)
        return popupWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tabID = tabID(for: webView) else { return }
        if BrowserStore.isUITesting {
            store?.uiTestingPopupDiagnostics.append(
                "jsClose href=\(webView.url?.absoluteString.prefix(80) ?? "nil")"
            )
        }
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

    func javaScriptPanelAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }

    func presentPanel(_ alert: NSAlert, for webView: WKWebView) async -> NSApplication.ModalResponse {
        if let window = webView.window {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}
