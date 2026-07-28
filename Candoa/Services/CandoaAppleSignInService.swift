import AppKit
import AuthenticationServices
import Foundation
import OSLog

@MainActor
final class CandoaAppleSignInService: NSObject {
    private static let logger = Logger(
        subsystem: "app.candoa.browser",
        category: "AppleSignIn"
    )
    private var authenticationSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var requestedURL: URL?
    private var browserLaunchFallbackTask: Task<Void, Never>?
    private var fallbackTimeoutTask: Task<Void, Never>?
    private var hasContinuedInSafari = false
    private var ignoresNextSessionCancellation = false
    private static weak var pendingService: CandoaAppleSignInService?

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
            throw CandoaAccountError.server("Sign in with Apple is already in progress.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            requestedURL = url
            Self.pendingService = self

            let completionHandler: @Sendable (URL?, (any Error)?) -> Void = {
                [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.completeAuthentication(
                        callbackURL: callbackURL,
                        error: error
                    )
                }
            }

            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(Self.callbackScheme),
                    completionHandler: completionHandler
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: Self.callbackScheme,
                    completionHandler: completionHandler
                )
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session

            if !session.start() {
                finish(
                    with: .failure(
                        CandoaAccountError.server(
                            "Candoa could not open Sign in with Apple."
                        )
                    )
                )
                return
            }

#if DEBUG
            // Arc can accept the AuthenticationServices request without ever
            // loading it when the Debug-only callback scheme is in use. Give
            // the system session first chance, then continue the same request
            // in Safari once if no browser has progressed it.
            browserLaunchFallbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                guard !Task.isCancelled,
                      self?.pendingContinuation != nil,
                      self?.requestedURL == url else {
                    return
                }
                self?.continueInSafari(url)
            }
#endif
        }
    }

    func handleCallbackURL(_ url: URL) -> Bool {
        guard isAppleCallback(url) else { return false }
        Self.logger.notice("Received the Sign in with Apple application callback.")
        guard pendingContinuation != nil else { return true }
        complete(with: url)
        return true
    }

    static func handleApplicationCallback(_ url: URL) -> Bool {
        pendingService?.handleCallbackURL(url) ?? false
    }

    private func completeAuthentication(
        callbackURL: URL?,
        error: (any Error)?
    ) {
        authenticationSession = nil

        if let error {
            let error = error as NSError
            if ignoresNextSessionCancellation,
               error.domain == ASWebAuthenticationSessionError.errorDomain,
               error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                ignoresNextSessionCancellation = false
                return
            }
            Self.logger.error(
                "Authentication session failed: \(error.domain, privacy: .public) \(error.code)"
            )
            finish(with: .failure(error))
            return
        }

        guard let callbackURL else {
            finish(with: .failure(CandoaAccountError.invalidResponse))
            return
        }

        if isAppleCallback(callbackURL) {
            complete(with: callbackURL)
            return
        }

        // Some default browsers incorrectly report the initial HTTPS request as
        // the authentication callback. Keep the one-time native intent active
        // and continue the same request in Safari, which reliably hands the
        // the custom-scheme result back to this app.
        if callbackURL == requestedURL,
           callbackURL.scheme == "https" {
            Self.logger.notice(
                "Default browser did not handle the authentication session; continuing in Safari."
            )
            continueInSafari(callbackURL)
            return
        }

        finish(with: .failure(CandoaAccountError.invalidResponse))
    }

    private func complete(with callbackURL: URL) {
        guard let components = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        ) else {
            finish(with: .failure(CandoaAccountError.invalidResponse))
            return
        }
        let values = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )
        if let code = values["code"], !code.isEmpty {
            finish(with: .success(code))
        } else {
            let message = values["error"]
                .map(Self.readableError)
                ?? "Candoa could not complete Sign in with Apple."
            finish(with: .failure(CandoaAccountError.server(message)))
        }
    }

    private func continueInSafari(_ url: URL) {
        guard pendingContinuation != nil, !hasContinuedInSafari else { return }
        hasContinuedInSafari = true
        browserLaunchFallbackTask?.cancel()
        browserLaunchFallbackTask = nil
        if let authenticationSession {
            ignoresNextSessionCancellation = true
            self.authenticationSession = nil
            authenticationSession.cancel()
        }

        guard let safariURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else {
            finish(
                with: .failure(
                    CandoaAccountError.server("Candoa could not open Safari for Apple sign-in.")
                )
            )
            return
        }

        fallbackTimeoutTask?.cancel()
        fallbackTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard !Task.isCancelled, self?.pendingContinuation != nil else { return }
            self?.finish(
                with: .failure(
                    CandoaAccountError.server("Sign in with Apple timed out. Please try again.")
                )
            )
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: safariURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.finish(with: .failure(error))
            }
        }
    }

    private func finish(with result: Result<String, any Error>) {
        authenticationSession?.cancel()
        authenticationSession = nil
        requestedURL = nil
        browserLaunchFallbackTask?.cancel()
        browserLaunchFallbackTask = nil
        fallbackTimeoutTask?.cancel()
        fallbackTimeoutTask = nil
        hasContinuedInSafari = false
        ignoresNextSessionCancellation = false
        if Self.pendingService === self {
            Self.pendingService = nil
        }
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
            return "Sign in with Apple was canceled."
        case "apple_account_not_linked":
            return "Apple could not be connected to this Candoa account."
        default:
            return "Candoa could not complete Sign in with Apple."
        }
    }
}

extension CandoaAppleSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first
            ?? ASPresentationAnchor()
    }
}
