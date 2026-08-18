import AppKit
import Foundation
import WebKit

extension WebViewCoordinator {
    /// Handles the Chrome Web Store button Candoa put on the page: download
    /// the item, then run it through the same install path as a file the
    /// person picked themselves — permission prompt and all. The page is told
    /// the outcome either way so its button never stays on "Adding…".
    func installWebStoreItem(itemID: String, name: String, in webView: WKWebView) {
        guard #available(macOS 15.4, *) else {
            reportWebStoreResult(installed: false, in: webView)
            presentWebStoreAlert(
                message: String(localized: "Extensions require macOS 15.4 or later."),
                informative: nil,
                for: webView
            )
            return
        }

        guard ChromeWebStore.isItemID(itemID) else {
            reportWebStoreResult(installed: false, in: webView)
            return
        }

        let displayName = name.isEmpty ? String(localized: "this extension") : name

        Task { @MainActor [weak self, weak webView] in
            do {
                let archiveURL = try await ChromeWebStore.downloadItem(itemID)
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                let outcome = try await WebExtensionManager.shared.install(from: archiveURL)
                guard let self, let webView else { return }
                switch outcome {
                case .installed:
                    self.reportWebStoreResult(installed: true, in: webView)
                case .declined:
                    self.reportWebStoreResult(installed: false, in: webView)
                }
            } catch {
                guard let self, let webView else { return }
                self.reportWebStoreResult(installed: false, in: webView)
                self.presentWebStoreAlert(
                    message: String(localized: "Couldn't add “\(displayName)”."),
                    informative: error.localizedDescription,
                    for: webView
                )
            }
        }
    }

    private func reportWebStoreResult(installed: Bool, in webView: WKWebView) {
        let state = installed ? "installed" : "failed"
        webView.evaluateJavaScript(
            "window.__candoaWebStoreResult && window.__candoaWebStoreResult(\"\(state)\")"
        )
    }

    private func presentWebStoreAlert(message: String, informative: String?, for webView: WKWebView) {
        let alert = NSAlert()
        alert.messageText = message
        if let informative {
            alert.informativeText = informative
        }
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = webView.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
