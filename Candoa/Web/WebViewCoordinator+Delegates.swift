import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // The page is going away; its hovered-link pill must not outlive it.
        if let tabID = tabID(for: webView) {
            store?.updateHoveredLink(tabID: tabID, href: nil)
        }
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
        reportWebsiteAppearanceForUITesting(from: webView)
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
