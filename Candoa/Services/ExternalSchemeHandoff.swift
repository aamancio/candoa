import AppKit
import WebKit

/// Which navigations belong to the OS instead of the web view. WKWebView
/// cannot load non-web schemes — before this existed a `claude://` or
/// `zoom://` navigation died as a silent provisional failure, breaking every
/// "open in app" handoff (issue #540; the Claude desktop app's OAuth deep
/// link was the one that bit us). Pure so the unit target can cover it.
enum ExternalSchemePolicy {
    /// Schemes the web view renders itself; everything else is handed to
    /// the system. `about`, `blob`, and `data` back ordinary page plumbing;
    /// `javascript` keeps bookmarklet-style links inert here.
    static let webViewSchemes: Set<String> = [
        "http", "https", "about", "blob", "data", "file", "javascript"
    ]

    /// Communication schemes Safari opens in their system apps without
    /// asking. Every other scheme gets the consent prompt — that prompt is
    /// the gate that keeps drive-by pages from launching apps.
    static let promptFreeSchemes: Set<String> = [
        "mailto", "tel", "facetime", "facetime-audio", "sms"
    ]

    static func requiresSystemHandoff(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !webViewSchemes.contains(scheme)
    }

    static func requiresConsent(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return !promptFreeSchemes.contains(scheme)
    }
}

/// Presents Safari's consent alert and performs the LaunchServices open.
@MainActor
enum ExternalSchemeHandoff {
    /// Windows with a consent sheet already up, by window number. A page
    /// that fires scheme navigations in a loop gets one prompt, not a stack.
    private static var windowsAwaitingConsent = Set<Int>()

    static func perform(_ url: URL, from webView: WKWebView) {
        // A web view without a window is warm-up or teardown plumbing;
        // nothing user-visible asked for this.
        guard let window = webView.window else { return }

        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(toOpen: url) else {
            presentNoHandlerAlert(for: url, on: window)
            return
        }

        guard ExternalSchemePolicy.requiresConsent(url) else {
            workspace.open(url)
            return
        }

        guard windowsAwaitingConsent.insert(window.windowNumber).inserted else { return }

        let appName = FileManager.default.displayName(atPath: appURL.path)
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "Do you want to allow this page to open “%@”?"),
            appName
        )
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        Task {
            let response = await alert.beginSheetModal(for: window)
            windowsAwaitingConsent.remove(window.windowNumber)
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func presentNoHandlerAlert(for url: URL, on window: NSWindow) {
        guard windowsAwaitingConsent.insert(window.windowNumber).inserted else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "There is no app installed to open “%@” links."),
            url.scheme ?? ""
        )
        alert.addButton(withTitle: String(localized: "OK"))
        Task {
            _ = await alert.beginSheetModal(for: window)
            windowsAwaitingConsent.remove(window.windowNumber)
        }
    }
}
