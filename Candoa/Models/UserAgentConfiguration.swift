import Foundation

/// The Develop menu's User Agent presets. Each case maps to a fixed
/// customUserAgent string; `.standard` means WebKit's own default.
enum UserAgentPreset: String, CaseIterable, Identifiable {
    case standard
    case safariMac
    case safariIPhone
    case safariIPad
    case edgeMac
    case edgeWindows
    case edgeAndroid
    case chromeMac
    case chromeWindows
    case chromeAndroid
    case chromeChromeOS
    case firefoxMac
    case firefoxWindows
    case firefoxAndroid

    var id: String { rawValue }

    /// Safari's User Agent submenu layout: the default alone, then one
    /// group per browser family, separated in the menu.
    static let menuSections: [[UserAgentPreset]] = [
        [.standard],
        [.safariMac],
        [.safariIPhone, .safariIPad],
        [.edgeMac, .edgeWindows, .edgeAndroid],
        [.chromeMac, .chromeWindows, .chromeAndroid, .chromeChromeOS],
        [.firefoxMac, .firefoxWindows, .firefoxAndroid]
    ]

    var title: String {
        switch self {
        case .standard:
            String(localized: "Default (Automatically Chosen)")
        case .safariMac:
            String(localized: "Safari — macOS")
        case .safariIPhone:
            String(localized: "Safari — iOS")
        case .safariIPad:
            String(localized: "Safari — iPadOS")
        case .edgeMac:
            String(localized: "Microsoft Edge — macOS")
        case .edgeWindows:
            String(localized: "Microsoft Edge — Windows")
        case .edgeAndroid:
            String(localized: "Microsoft Edge — Android")
        case .chromeMac:
            String(localized: "Google Chrome — macOS")
        case .chromeWindows:
            String(localized: "Google Chrome — Windows")
        case .chromeAndroid:
            String(localized: "Google Chrome — Android")
        case .chromeChromeOS:
            String(localized: "Google Chrome — ChromeOS")
        case .firefoxMac:
            String(localized: "Firefox — macOS")
        case .firefoxWindows:
            String(localized: "Firefox — Windows")
        case .firefoxAndroid:
            String(localized: "Firefox — Android")
        }
    }

    /// The value for WKWebView.customUserAgent; nil clears the override.
    var userAgent: String? {
        switch self {
        case .standard:
            nil
        case .safariMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        case .safariIPhone:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        case .safariIPad:
            "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        case .edgeMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"
        case .edgeWindows:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"
        case .edgeAndroid:
            "Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 EdgA/138.0.0.0"
        case .chromeMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        case .chromeWindows:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        case .chromeAndroid:
            "Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36"
        case .chromeChromeOS:
            "Mozilla/5.0 (X11; CrOS x86_64 16181.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        case .firefoxMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0"
        case .firefoxWindows:
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:141.0) Gecko/20100101 Firefox/141.0"
        case .firefoxAndroid:
            "Mozilla/5.0 (Android 15; Mobile; rv:141.0) Gecko/141.0 Firefox/141.0"
        }
    }
}

enum UserAgentConfiguration {
    /// Resolves a stored customUserAgent back to its preset so the menu can
    /// check the matching item. nil or an empty string is `.standard`; a
    /// string no preset produced is a custom user agent (Other…), which
    /// leaves every preset unchecked.
    static func preset(matching userAgent: String?) -> UserAgentPreset? {
        guard let userAgent, !userAgent.isEmpty else { return .standard }
        return UserAgentPreset.allCases.first { $0.userAgent == userAgent }
    }
}
