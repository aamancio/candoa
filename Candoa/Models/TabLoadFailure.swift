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
        /// A sign-in redirect that came back and then did nothing: the page
        /// carries an OAuth response but renders no content and never moves
        /// on. Its own script was meant to finish the handshake and send the
        /// person home; when that fails there is nothing on screen to act on.
        case emptySignInRedirect
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

    /// Whether a URL is an OAuth/OpenID provider handing an answer back to
    /// the site. Both halves are required — a response parameter *and* the
    /// `state` every such flow round-trips — so an ordinary page carrying a
    /// `code` query (a promo code, a country code) is never mistaken for one.
    static func carriesSignInResponse(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }

        var names = Set((components.queryItems ?? []).map(\.name))
        // Implicit and hybrid flows answer in the fragment, which URLComponents
        // hands back as one opaque string.
        if let fragment = components.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            names.formUnion((fragmentComponents.queryItems ?? []).map(\.name))
        }

        let answers: Set<String> = ["code", "id_token", "access_token", "error"]
        return names.contains("state") && !names.isDisjoint(with: answers)
    }

    var symbolName: String {
        switch kind {
        case .offline: return "wifi.slash"
        case .dnsFailure: return "globe.badge.chevron.backward"
        case .connectionFailure: return "exclamationmark.triangle"
        case .processTerminated: return "arrow.clockwise.circle"
        case .generic: return "exclamationmark.triangle"
        case .emptySignInRedirect: return "arrow.uturn.backward.circle"
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
        case .emptySignInRedirect:
            return String(localized: "Sign-In Didn't Finish")
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
        case .emptySignInRedirect:
            return String(
                localized: "The site sent you back from signing in, but the page it landed on is empty."
            )
        }
    }

    var retryTitle: String {
        switch kind {
        case .processTerminated:
            return String(localized: "Reload Page")
        case .emptySignInRedirect:
            // Reloading is the one thing that cannot work: the authorization
            // code in this URL is spent, so every reload lands here again.
            return String(localized: "Back to the Site")
        default:
            return String(localized: "Try Again")
        }
    }
}
