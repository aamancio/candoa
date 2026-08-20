import AppKit
import Foundation

/// Per-site remembered allowances for links that open other apps (zoom:,
/// spotify:, custom schemes), stored like SitePermissionConfiguration's
/// overrides: one UserDefaults key holding a small JSON map, readable through
/// `@AppStorage` so Site Info re-renders when an allowance changes. Keys are
/// the page's effective origin; values map a lowercase scheme to a decision.
///
/// Only "allow" is ever remembered. Declining the prompt is a one-time
/// answer — the next click asks again, the way Safari's open-in-app prompt
/// behaves — so the stored map never accumulates deny rows a person would
/// then have to discover and undo.
enum ExternalAppLinkConfiguration {
    static let storageKey = "Candoa.ExternalSchemeAllowances"

    /// Schemes WebKit renders itself (or that never leave the page). A
    /// navigation to anything else is a request to open another app.
    private static let webSchemes: Set<String> = [
        "http", "https", "about", "file", "data", "blob", "javascript", "applewebdata",
    ]

    static func isExternalAppLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !webSchemes.contains(scheme)
    }

    static func isAllowed(scheme: String, pageURL: URL?, storedOverrides: String? = nil) -> Bool {
        guard
            let pageURL,
            let origin = SitePermissionConfiguration.originKey(for: pageURL)
        else {
            return false
        }
        return overrides(from: storedOverrides)[origin]?[scheme.lowercased()] == "allow"
    }

    static func setAllowed(_ allowed: Bool, scheme: String, pageURL: URL) {
        guard let origin = SitePermissionConfiguration.originKey(for: pageURL) else { return }

        var all = overrides(from: nil)
        var site = all[origin] ?? [:]
        if allowed {
            site[scheme.lowercased()] = "allow"
        } else {
            site.removeValue(forKey: scheme.lowercased())
        }
        if site.isEmpty {
            all.removeValue(forKey: origin)
        } else {
            all[origin] = site
        }
        UserDefaults.standard.set(encoded(all), forKey: storageKey)
    }

    /// The schemes this page's origin has remembered, for Site Info's rows.
    static func allowedSchemes(for pageURL: URL, storedOverrides: String? = nil) -> [String] {
        guard let origin = SitePermissionConfiguration.originKey(for: pageURL) else { return [] }
        return (overrides(from: storedOverrides)[origin] ?? [:]).keys.sorted()
    }

    static func resetAllowances(for pageURL: URL) {
        guard let origin = SitePermissionConfiguration.originKey(for: pageURL) else { return }
        var all = overrides(from: nil)
        all.removeValue(forKey: origin)
        UserDefaults.standard.set(encoded(all), forKey: storageKey)
    }

    private static func overrides(from storedValue: String?) -> [String: [String: String]] {
        let value = storedValue ?? UserDefaults.standard.string(forKey: storageKey) ?? ""
        guard
            let data = value.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private static func encoded(_ overrides: [String: [String: String]]) -> String {
        guard
            let data = try? JSONEncoder().encode(overrides),
            let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }
}

/// Fulfils navigations whose scheme belongs to another app (classification
/// lives on ExternalAppLinkConfiguration with the rest of the pure logic).
@MainActor
enum ExternalAppLinkService {
    static func isExternalAppLink(_ url: URL) -> Bool {
        ExternalAppLinkConfiguration.isExternalAppLink(url)
    }

    /// The display name of the app registered for the URL's scheme, or nil
    /// when macOS knows no handler. UI-test runs answer from the fixture
    /// environment so the prompt is testable without the app installed.
    static func handlerAppName(for url: URL) -> String? {
        if BrowserStore.isUITesting {
            return ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_EXTERNAL_APP_NAME"]
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let name = FileManager.default.displayName(atPath: appURL.path)
        // Finder's display name keeps ".app" when extensions are shown;
        // the prompt should always read "Zoom", never "zoom.us.app".
        return (name as NSString).deletingPathExtension
    }

    /// Hands the URL to the system. UI-test runs record instead of opening,
    /// so a test can assert the handoff without launching Zoom.
    static func open(_ url: URL, store: BrowserStore?) {
        if BrowserStore.isUITesting {
            store?.uiTestingExternalAppDiagnostics.append(
                "open=\(url.absoluteString.prefix(80))"
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Routes one external-scheme navigation: mailto goes straight to the
    /// default mail client, a remembered site allowance opens silently, and
    /// everything else asks first. No registered handler means there is
    /// nothing to offer — the click stays a no-op, matching the pre-prompt
    /// behavior, rather than surfacing a dead-end dialog.
    static func handle(_ url: URL, pageURL: URL?, window: NSWindow?, store: BrowserStore?) {
        guard let scheme = url.scheme?.lowercased() else { return }

        if scheme == "mailto" {
            open(url, store: store)
            return
        }

        if ExternalAppLinkConfiguration.isAllowed(scheme: scheme, pageURL: pageURL) {
            open(url, store: store)
            return
        }

        guard let appName = handlerAppName(for: url) else {
            if BrowserStore.isUITesting {
                store?.uiTestingExternalAppDiagnostics.append("noHandler=\(scheme)")
            }
            return
        }

        presentPrompt(for: url, scheme: scheme, appName: appName, pageURL: pageURL, window: window, store: store)
    }

    private static func presentPrompt(
        for url: URL,
        scheme: String,
        appName: String,
        pageURL: URL?,
        window: NSWindow?,
        store: BrowserStore?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Do you want to allow this page to open “\(appName)”?")
        if let host = pageURL?.host(percentEncoded: false), !host.isEmpty {
            alert.informativeText = String(localized: "The link on \(host) opens in another app.")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(
                localized: "Always allow \(host) to open \(scheme) links"
            )
        } else {
            alert.informativeText = String(localized: "This link opens in another app.")
        }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                if BrowserStore.isUITesting {
                    store?.uiTestingExternalAppDiagnostics.append("declined=\(scheme)")
                }
                return
            }
            if alert.suppressionButton?.state == .on, let pageURL {
                ExternalAppLinkConfiguration.setAllowed(true, scheme: scheme, pageURL: pageURL)
            }
            open(url, store: store)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
