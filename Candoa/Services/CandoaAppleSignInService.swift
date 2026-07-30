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
    private var authenticationAttemptID: UUID?
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var requestedURL: URL?
    private var fallbackTimeoutTask: Task<Void, Never>?
    private var externalBrowserReturnTask: Task<Void, Never>?
    private var externalBrowserReturnObserver: NSObjectProtocol?
    private var externalBrowserActivationObserver: NSObjectProtocol?
    private var hasActivatedSafari = false
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
            let attemptID = UUID()
            authenticationAttemptID = attemptID
            pendingContinuation = continuation
            requestedURL = url
            Self.pendingService = self

            let completionHandler: @Sendable (URL?, (any Error)?) -> Void = {
                [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.completeAuthentication(
                        callbackURL: callbackURL,
                        error: error,
                        attemptID: attemptID
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

    static func handleApplicationCallback(_ url: URL) -> Bool {
        pendingService?.handleCallbackURL(url) ?? false
    }

    private func completeAuthentication(
        callbackURL: URL?,
        error: (any Error)?,
        attemptID: UUID
    ) {
        guard authenticationAttemptID == attemptID else {
            Self.logger.notice(
                "Ignoring a callback from a superseded Apple authentication attempt."
            )
            return
        }
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
            Self.logger.notice("Completing Apple authentication with an exchange code.")
            finish(with: .success(code))
        } else if values["error"] == "account_already_linked_to_different_user" {
            Self.logger.notice(
                "Apple identity belongs to an existing account; falling back to sign-in."
            )
            finish(with: .failure(CandoaAccountError.appleAccountAlreadyLinked))
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
        observeExternalBrowserReturn()
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

    private func observeExternalBrowserReturn() {
        guard externalBrowserReturnObserver == nil else { return }
        externalBrowserActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
            application.bundleIdentifier == "com.apple.Safari" else {
                return
            }
            Task { @MainActor [weak self] in
                self?.hasActivatedSafari = true
            }
        }
        externalBrowserReturnObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.hasContinuedInSafari,
                      self.hasActivatedSafari,
                      self.pendingContinuation != nil else {
                    return
                }

                // A successful custom-scheme callback can activate Candoa just
                // before application(_:open:) delivers the URL. Give that
                // callback a chance to finish before treating a plain return
                // from Safari as cancellation — on a busy system URL delivery
                // can lag activation by well over a second.
                self.externalBrowserReturnTask?.cancel()
                self.externalBrowserReturnTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled,
                          let self,
                          self.hasContinuedInSafari,
                          self.pendingContinuation != nil else {
                        return
                    }
                    self.finish(with: .failure(Self.canceledLoginError))
                }
            }
        }
    }

    private func finish(with result: Result<String, any Error>) {
        authenticationSession?.cancel()
        authenticationSession = nil
        authenticationAttemptID = nil
        requestedURL = nil
        fallbackTimeoutTask?.cancel()
        fallbackTimeoutTask = nil
        externalBrowserReturnTask?.cancel()
        externalBrowserReturnTask = nil
        if let externalBrowserReturnObserver {
            NotificationCenter.default.removeObserver(externalBrowserReturnObserver)
            self.externalBrowserReturnObserver = nil
        }
        if let externalBrowserActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                externalBrowserActivationObserver
            )
            self.externalBrowserActivationObserver = nil
        }
        hasActivatedSafari = false
        hasContinuedInSafari = false
        ignoresNextSessionCancellation = false
        if Self.pendingService === self {
            Self.pendingService = nil
        }
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(with: result)
    }

    private static var canceledLoginError: NSError {
        NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        )
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
