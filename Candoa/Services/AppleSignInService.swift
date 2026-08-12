import AuthenticationServices
import Foundation
import OSLog

@MainActor
final class AppleSignInService {
    private static let logger = Logger(
        subsystem: "app.candoa.browser",
        category: "AppleSignIn"
    )
    private var pendingContinuation: CheckedContinuation<String, any Error>?

    private static var callbackScheme: String {
#if DEBUG
        let configuredScheme =
            ProcessInfo.processInfo.environment["CANDOA_APPLE_CALLBACK_SCHEME"]
        if let configuredScheme,
           configuredScheme == "candoa" || configuredScheme == "candoa-dev" {
            return configuredScheme
        }
        return "candoa-dev"
#else
        return "candoa"
#endif
    }

    func authenticate(at url: URL) async throws -> String {
        guard pendingContinuation == nil else {
            throw AccountError.server("Sign in with Apple is already in progress.")
        }
        // Candoa's own sign-in always lives in the app's dedicated Sign In
        // window. Routing through ASWebAuthenticationSession would hand the
        // session to whatever the default browser is; the in-app host only
        // exists for sessions arriving from the system (#253).
        guard let hostService = WebAuthenticationSessionHostService.shared else {
            throw AccountError.server("Candoa could not open Sign in with Apple.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            let request = FirstPartyWebAuthenticationRequest(
                url: url,
                callbackScheme: Self.callbackScheme,
                onComplete: { [weak self] callbackURL in
                    self?.complete(with: callbackURL)
                },
                onCancel: { [weak self] error in
                    let error = error as NSError
                    if error.domain != ASWebAuthenticationSessionError.errorDomain
                        || error.code != ASWebAuthenticationSessionError
                            .canceledLogin.rawValue {
                        Self.logger.error(
                            "Hosted Apple sign-in failed: \(error.domain, privacy: .public) \(error.code)"
                        )
                    }
                    self?.finish(with: .failure(error))
                }
            )
            hostService.hostFirstPartySession(request)
        }
    }

    func handleCallbackURL(_ url: URL) -> Bool {
        guard isAppleCallback(url) else { return false }
        Self.logger.notice("Received the Sign in with Apple application callback.")
        guard pendingContinuation != nil else {
            Self.logger.error(
                "Received the Apple application callback without a pending authentication."
            )
            return true
        }
        complete(with: url)
        return true
    }

    private func complete(with callbackURL: URL) {
        guard let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ) else {
            finish(with: .failure(AccountError.invalidResponse))
            return
        }
        let values = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )
        if let code = values["code"], !code.isEmpty {
            Self.logger.notice("Completing Apple authentication with an exchange code.")
            finish(with: .success(code))
        } else if values["error"] == "account_already_linked_to_different_user" {
            Self.logger.notice(
                "Apple identity belongs to an existing account; falling back to sign-in."
            )
            finish(with: .failure(AccountError.appleAccountAlreadyLinked))
        } else {
            let message = values["error"]
                .map(Self.readableError)
                ?? String(localized: "Candoa could not complete Sign in with Apple.")
            finish(with: .failure(AccountError.server(message)))
        }
    }

    private func finish(with result: Result<String, any Error>) {
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(with: result)
    }

    private func isAppleCallback(_ url: URL) -> Bool {
        url.scheme == Self.callbackScheme
            && url.host == "auth"
            && url.path == "/apple"
    }

    private static func readableError(_ value: String) -> String {
        switch value {
        case "access_denied":
            return String(localized: "Sign in with Apple was canceled.")
        case "apple_account_not_linked":
            return String(localized: "Apple could not be connected to this Candoa account.")
        default:
            return String(localized: "Candoa could not complete Sign in with Apple.")
        }
    }
}
