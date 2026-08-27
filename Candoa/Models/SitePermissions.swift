import Foundation

/// The per-site behaviors Candoa actually implements today. Site Info only
/// ever lists these — permissions the browser cannot enforce (location,
/// autoplay) are deliberately absent rather than shown as inert controls.
/// Notifications qualify because Candoa provides the Notification API
/// itself (`WebPageScripts.notificationShimScript` + `WebNotificationService`).
enum SitePermission: String, CaseIterable, Codable, Identifiable {
    case camera
    case microphone
    case notifications
    case popupWindows = "popup-windows"

    var id: String { rawValue }

    /// Pop-up creation is a synchronous WebKit delegate decision, so it can
    /// only be allowed or blocked — there is no moment to ask.
    var supportsAsking: Bool {
        switch self {
        case .camera, .microphone, .notifications:
            return true
        case .popupWindows:
            return false
        }
    }

    var defaultDecision: SitePermissionDecision {
        switch self {
        case .camera, .microphone, .notifications:
            return .ask
        case .popupWindows:
            // Matches Candoa's long-standing behavior: window.open works
            // unless a site is explicitly blocked from Site Info.
            return .allow
        }
    }
}

enum SitePermissionDecision: String, Codable, CaseIterable {
    case ask
    case allow
    case deny
}

/// Per-origin permission decisions, stored like Developer Mode's site
/// overrides: one UserDefaults key holding a small JSON map, readable through
/// `@AppStorage` so SwiftUI surfaces re-render when a decision changes. Keys
/// are effective origins (scheme://host:port), not bare hosts, so
/// `http://example.com` and `https://example.com` decide independently.
enum SitePermissionConfiguration {
    static let storageKey = "Candoa.SitePermissionOverrides"

    static func decision(
        for permission: SitePermission,
        url: URL,
        storedOverrides: String? = nil
    ) -> SitePermissionDecision {
        guard let origin = originKey(for: url) else { return permission.defaultDecision }
        return decision(for: permission, originKey: origin, storedOverrides: storedOverrides)
    }

    static func decision(
        for permission: SitePermission,
        originKey: String,
        storedOverrides: String? = nil
    ) -> SitePermissionDecision {
        guard
            let stored = overrides(from: storedOverrides)[originKey]?[permission.rawValue],
            let decision = SitePermissionDecision(rawValue: stored)
        else {
            return permission.defaultDecision
        }
        return decision
    }

    static func setDecision(
        _ decision: SitePermissionDecision,
        for permission: SitePermission,
        url: URL
    ) {
        guard let origin = originKey(for: url) else { return }

        var all = overrides(from: nil)
        var site = all[origin] ?? [:]
        if decision == permission.defaultDecision {
            site.removeValue(forKey: permission.rawValue)
        } else {
            site[permission.rawValue] = decision.rawValue
        }
        if site.isEmpty {
            all.removeValue(forKey: origin)
        } else {
            all[origin] = site
        }
        UserDefaults.standard.set(encoded(all), forKey: storageKey)
    }

    static func resetDecisions(for url: URL) {
        guard let origin = originKey(for: url) else { return }
        var all = overrides(from: nil)
        all.removeValue(forKey: origin)
        UserDefaults.standard.set(encoded(all), forKey: storageKey)
    }

    static func hasDecisions(for url: URL, storedOverrides: String? = nil) -> Bool {
        guard let origin = originKey(for: url) else { return false }
        return !(overrides(from: storedOverrides)[origin] ?? [:]).isEmpty
    }

    /// The effective origin a decision applies to. Nil for URLs that have no
    /// origin a permission could attach to (files, about pages).
    static func originKey(for url: URL) -> String? {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(percentEncoded: false)?.lowercased(),
            !host.isEmpty
        else {
            return nil
        }
        return originKey(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// Variant for WebKit security origins, which report the default port
    /// as 0 the same way URL reports it as nil.
    static func originKey(scheme: String, host: String, port: Int) -> String? {
        let normalizedScheme = scheme.lowercased()
        let normalizedHost = host.lowercased()
        guard !normalizedScheme.isEmpty, !normalizedHost.isEmpty else { return nil }

        let effectivePort: Int
        if port != 0 {
            effectivePort = port
        } else {
            switch normalizedScheme {
            case "https": effectivePort = 443
            case "http": effectivePort = 80
            default: effectivePort = 0
            }
        }
        return "\(normalizedScheme)://\(normalizedHost):\(effectivePort)"
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

/// What Site Info can truthfully say about the displayed page, derived only
/// from WKWebView's public security surface (`hasOnlySecureContent` and
/// `serverTrust`) — never more than WebKit exposes.
struct SiteSecuritySummary: Equatable {
    enum Connection: Equatable {
        /// HTTPS with every subresource loaded securely.
        case secure
        /// HTTPS main frame, but some content arrived unencrypted.
        case mixedContent
        /// Cleartext HTTP or another unencrypted scheme.
        case insecure
        /// Localhost-class hosts get accurate local-development wording
        /// instead of a misleading "not secure" warning.
        case localDevelopment
        /// file: URLs — a file on this Mac, no network connection at all.
        case localFile
    }

    let connection: Connection
    /// Subject summary of the served leaf certificate, when WebKit has one.
    let certificateSubject: String?
    /// The leaf certificate's not-after date, when it can be read.
    let certificateExpiry: Date?
}
