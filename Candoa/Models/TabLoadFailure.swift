import Foundation

/// A navigation or WebContent failure the user needs to see and act on.
/// One value per tab; cleared the moment real content commits again.
struct TabLoadFailure: Equatable {
    enum Kind: Equatable {
        case offline
        case dnsFailure
        case connectionFailure
        case processTerminated
        case generic
    }

    let kind: Kind
    let failedURL: URL?
    let message: String

    /// Classifies a WebKit navigation error, or nil for errors that are part
    /// of normal browsing and must never surface recovery UI: user-initiated
    /// cancellations, loads interrupted because they became downloads or
    /// were handed to another handler.
    static func make(from error: NSError, failedURL: URL?) -> TabLoadFailure? {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled:
                return nil
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorNetworkConnectionLost:
                return TabLoadFailure(kind: .offline, failedURL: failedURL, message: error.localizedDescription)
            case NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return TabLoadFailure(kind: .dnsFailure, failedURL: failedURL, message: error.localizedDescription)
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return TabLoadFailure(kind: .connectionFailure, failedURL: failedURL, message: error.localizedDescription)
            default:
                return TabLoadFailure(kind: .generic, failedURL: failedURL, message: error.localizedDescription)
            }
        }

        if error.domain == "WebKitErrorDomain" {
            // 102: frame load interrupted (downloads, custom-scheme handoff).
            // 204: plug-in handled the load. Both are successful outcomes.
            if error.code == 102 || error.code == 204 {
                return nil
            }
            return TabLoadFailure(kind: .generic, failedURL: failedURL, message: error.localizedDescription)
        }

        return TabLoadFailure(kind: .generic, failedURL: failedURL, message: error.localizedDescription)
    }

    var symbolName: String {
        switch kind {
        case .offline: return "wifi.slash"
        case .dnsFailure: return "globe.badge.chevron.backward"
        case .connectionFailure: return "exclamationmark.triangle"
        case .processTerminated: return "arrow.clockwise.circle"
        case .generic: return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch kind {
        case .offline:
            return String(localized: "You're Offline")
        case .dnsFailure:
            return String(localized: "Server Not Found")
        case .connectionFailure:
            return String(localized: "Can't Open This Page")
        case .processTerminated:
            return String(localized: "This Page Had a Problem")
        case .generic:
            return String(localized: "Page Failed to Load")
        }
    }

    var guidance: String {
        switch kind {
        case .offline:
            return String(localized: "This page will load automatically when your connection returns.")
        case .dnsFailure, .connectionFailure, .generic:
            return message
        case .processTerminated:
            return String(localized: "Something went wrong showing this page. Your tab is still here.")
        }
    }

    var retryTitle: String {
        kind == .processTerminated
            ? String(localized: "Reload Page")
            : String(localized: "Try Again")
    }
}
