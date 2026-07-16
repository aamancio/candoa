import AuthenticationServices
import Foundation
import Security

/// Requests the system's one-time browser passkey permission after Apple has
/// granted the managed browser credential entitlement to Candoa's signature.
/// Unentitled development builds remain silent and continue to work normally.
@MainActor
final class BrowserPasskeyAuthorizationService {
    private static let entitlement = "com.apple.developer.web-browser.public-key-credential" as CFString

    private let credentialManager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
    private var hasRequestedAuthorization = false

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization, hasManagedEntitlement else { return }
        guard credentialManager.authorizationStateForPlatformCredentials == .notDetermined else { return }

        hasRequestedAuthorization = true
        credentialManager.requestAuthorizationForPublicKeyCredentials { _ in }
    }

    private var hasManagedEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, Self.entitlement, nil) as? Bool == true
    }
}
