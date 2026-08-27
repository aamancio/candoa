import AuthenticationServices
import Foundation
import Security

/// Requests the system's one-time browser passkey permission after Apple has
/// granted the managed browser credential entitlement to Candoa's signature.
/// Unentitled development builds remain silent and continue to work normally.
@MainActor
final class BrowserPasskeyAuthorizationService {
    private nonisolated static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    private let credentialManager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization, Self.hasManagedEntitlement else { return }
        guard credentialManager.authorizationStateForPlatformCredentials == .notDetermined else { return }

        hasRequestedAuthorization = true
        credentialManager.requestAuthorizationForPublicKeyCredentials { _ in }
    }

    /// Also consulted by the built-in virtual authenticator (issue #506),
    /// which stands in exactly while this is false.
    nonisolated static var hasManagedEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, Self.entitlement as CFString, nil) as? Bool == true
    }
}
