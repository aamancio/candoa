import Foundation

/// The Develop menu's User Agent presets. Each case maps to a fixed
/// customUserAgent string; `.standard` means WebKit's own default.
enum UserAgentPreset: String, CaseIterable, Identifiable {
    case standard
    case safariMac
    case safariIPhone
    case safariIPad
    case chromeMac
    case firefoxMac
    case edgeMac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            String(localized: "Default")
        case .safariMac:
            String(localized: "Safari — macOS")
        case .safariIPhone:
            String(localized: "Safari — iOS")
        case .safariIPad:
            String(localized: "Safari — iPadOS")
        case .chromeMac:
            String(localized: "Google Chrome — macOS")
        case .firefoxMac:
            String(localized: "Firefox — macOS")
        case .edgeMac:
            String(localized: "Microsoft Edge — macOS")
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
        case .chromeMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
        case .firefoxMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:141.0) Gecko/20100101 Firefox/141.0"
        case .edgeMac:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"
        }
    }
}

enum UserAgentConfiguration {
    /// Resolves a stored customUserAgent back to its preset so the menu can
    /// check the matching item; nil or an unrecognized string is `.standard`.
    static func preset(matching userAgent: String?) -> UserAgentPreset {
        guard let userAgent else { return .standard }
        return UserAgentPreset.allCases.first { $0.userAgent == userAgent } ?? .standard
    }
}
