import Foundation

/// Plain language for what an extension is asking for. Manifests speak in API
/// names — `activeTab`, `declarativeNetRequest`, `<all_urls>` — which say
/// nothing to the person deciding whether to trust one, so the install and
/// access prompts show Chrome-style sentences instead: what the extension can
/// do, in the order that matters, with the API names left out entirely.
///
/// Permissions with no line here are deliberately silent, exactly as they are
/// in Chrome: storage, alarms or context menus tell nobody anything useful,
/// and listing them buries the ones that do.
enum WebExtensionPermissionCopy {
    /// The lines to show, website access first — it is almost always the one
    /// that matters — then the capabilities worth naming, deduplicated.
    static func warnings(permissions: [String], allHosts: Bool, hosts: [String]) -> [String] {
        var lines: [String] = []
        if let website = websiteWarning(allHosts: allHosts, hosts: hosts) {
            lines.append(website)
        }
        for permission in permissions.sorted() {
            guard let line = capabilityWarning(for: permission) else { continue }
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    /// How many hosts to name before the line turns into a count. Chrome
    /// scrolls a long list; an alert can't, so the tail is summarized.
    private static let namedHostLimit = 5

    static func websiteWarning(allHosts: Bool, hosts: [String]) -> String? {
        if allHosts {
            return String(localized: "Read and change all your data on all websites")
        }
        let described = hosts.map(describe(host:))
        guard !described.isEmpty else { return nil }

        if described.count <= namedHostLimit {
            let list = ListFormatter.localizedString(byJoining: described)
            return String(localized: "Read and change your data on \(list)")
        }
        let named = Array(described.prefix(namedHostLimit))
        let remaining = described.count - named.count
        let list = ListFormatter.localizedString(
            byJoining: named + [String(localized: "\(remaining) more sites")]
        )
        return String(localized: "Read and change your data on \(list)")
    }

    /// `*.example.com` covers the whole domain, so say so rather than
    /// printing a match pattern at someone.
    private static func describe(host: String) -> String {
        guard host.hasPrefix("*.") else { return host }
        let domain = String(host.dropFirst(2))
        return String(localized: "all \(domain) sites")
    }

    private static func capabilityWarning(for permission: String) -> String? {
        switch permission {
        case "tabs", "webNavigation":
            return String(localized: "Read your browsing history")
        case "history":
            return String(localized: "Read and change your browsing history")
        case "bookmarks":
            return String(localized: "Read and change your bookmarks")
        case "downloads":
            return String(localized: "Manage your downloads")
        case "topSites":
            return String(localized: "Read the list of sites you visit most")
        case "geolocation":
            return String(localized: "Detect your physical location")
        case "clipboardRead":
            return String(localized: "Read what you copy and paste")
        case "notifications":
            return String(localized: "Show you notifications")
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess":
            return String(localized: "Block content on the pages you visit")
        case "management":
            return String(localized: "Manage your other extensions")
        case "nativeMessaging":
            return String(localized: "Talk to apps on your Mac")
        case "privacy":
            return String(localized: "Change your privacy settings")
        case "proxy":
            return String(localized: "Send all your traffic through a proxy it picks")
        case "debugger":
            return String(localized: "Attach a debugger to the pages you visit")
        case "desktopCapture", "tabCapture":
            return String(localized: "Capture what's on your screen")
        case "cookies":
            return String(localized: "Read and change cookies for the sites it can reach")
        default:
            return nil
        }
    }

    /// The alert body: Chrome's "It can:" followed by the lines, bulleted once
    /// there is more than one. An extension that asks for nothing worth
    /// naming says so plainly instead of showing an empty list.
    static func informativeText(for warnings: [String]) -> String {
        switch warnings.count {
        case 0:
            return String(localized: "It doesn't ask for access to your data.")
        case 1:
            return String(localized: "It can:\n\n\(warnings[0])")
        default:
            let bullets = warnings.map { "•  \($0)" }.joined(separator: "\n")
            return String(localized: "It can:\n\n\(bullets)")
        }
    }
}
