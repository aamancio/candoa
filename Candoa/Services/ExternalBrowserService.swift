import AppKit

/// Lists the other browsers installed on this Mac and hands the current page
/// off to one of them (the Develop menu's "Open Page With" submenu).
@MainActor
enum ExternalBrowserService {
    struct Browser: Identifiable, Equatable {
        let id: String        // bundle identifier
        let name: String      // localized display name
        let appURL: URL
    }

    /// The installed HTTPS handlers other than Candoa, sorted by name.
    /// Computed once and cached — menu validation runs on every open, and
    /// LaunchServices enumeration is too slow to repeat per render.
    static func installedBrowsers() -> [Browser] {
        if let cachedBrowsers {
            return cachedBrowsers
        }

        let browsers = queryInstalledBrowsers()
        cachedBrowsers = browsers
        return browsers
    }

    static func open(_ url: URL, with browser: Browser) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: browser.appURL,
            configuration: configuration
        )
    }

    private static var cachedBrowsers: [Browser]?

    private static func queryInstalledBrowsers() -> [Browser] {
        guard let probeURL = URL(string: "https://candoa.app") else { return [] }

        let ownBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs = Set<String>()
        var browsers: [Browser] = []

        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probeURL) {
            guard
                let bundle = Bundle(url: appURL),
                let bundleID = bundle.bundleIdentifier,
                bundleID.caseInsensitiveCompare(ownBundleID ?? "") != .orderedSame,
                seenBundleIDs.insert(bundleID.lowercased()).inserted
            else {
                continue
            }

            let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? FileManager.default.displayName(atPath: appURL.path)
            browsers.append(Browser(id: bundleID, name: name, appURL: appURL))
        }

        return browsers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
