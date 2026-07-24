import AppKit
import AuthenticationServices
import os

@MainActor
private final class AuthenticationAnchorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class AuthenticationHelperDelegate: NSObject,
    NSApplicationDelegate,
    ASWebAuthenticationPresentationContextProviding {
    private static let callbackScheme = "candoa-auth"
    private static let relayHost = "relay"
    private static let launchScheme = "candoa-auth-helper-launch"
    private static let logger = Logger(
        subsystem: "app.candoa.browser.AuthenticationHelper",
        category: "Account"
    )

    private var anchorWindow: NSWindow?
    private var authenticationSession: ASWebAuthenticationSession?
    private var authenticationTimeoutTask: Task<Void, Never>?
    private var hasFinished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let argumentURL = ProcessInfo.processInfo.arguments
            .dropFirst()
            .compactMap(URL.init(string:))
            .first(where: { $0.scheme?.lowercased() == "https" }) {
            startAuthentication(at: argumentURL)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let launchURL = urls.first(where: {
            $0.scheme?.lowercased() == Self.launchScheme && $0.host == "start"
        }),
        let startURLString = URLComponents(
            url: launchURL,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "url" })?.value,
        let startURL = URL(string: startURLString),
        startURL.scheme?.lowercased() == "https" else {
            Self.logger.error("Authentication helper received an invalid launch URL")
            relay(error: "invalid_request")
            return
        }
        startAuthentication(at: startURL)
    }

    private func startAuthentication(at startURL: URL) {
        guard authenticationSession == nil else {
            Self.logger.error("Authentication helper received a second request while still active")
            relay(error: "authentication_in_progress")
            return
        }
        Self.logger.info(
            "Authentication helper received the start URL host=\(startURL.host ?? "none", privacy: .public)"
        )

        let window = makeAnchorWindow()
        anchorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let session = ASWebAuthenticationSession(
            url: startURL,
            callbackURLScheme: Self.callbackScheme,
            completionHandler: makeAuthenticationCompletionHandler(for: self)
        )
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authenticationSession = session

        guard session.start() else {
            authenticationSession = nil
            Self.logger.error("The system refused to start the authentication helper session")
            relay(error: "could_not_start")
            return
        }
        reactivateAfterSystemWindowAppears(for: session)
        scheduleAuthenticationTimeout()
        Self.logger.info("Authentication helper session started")
    }

    func authenticationDidComplete(callbackURL: URL?, error: (any Error)?) {
        guard !hasFinished else { return }
        authenticationSession = nil
        if let callbackURL {
            Self.logger.info("Authentication helper received the callback URL")
            relay(callbackURL: callbackURL)
        } else if let authenticationError = error as NSError?,
                  authenticationError.domain == ASWebAuthenticationSessionError.errorDomain,
                  authenticationError.code
                    == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
            Self.logger.info("Authentication helper session was cancelled")
            relay(error: "cancelled")
        } else {
            let authenticationError = error as NSError?
            Self.logger.error(
                "Authentication helper session failed: domain=\(authenticationError?.domain ?? "none", privacy: .public) code=\(authenticationError?.code ?? 0)"
            )
            relay(error: "failed")
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow ?? makeAnchorWindow()
    }

    private func makeAnchorWindow() -> NSWindow {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let origin = NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        let window = AuthenticationAnchorWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0.01
        window.hasShadow = false
        return window
    }

    private func relay(callbackURL: URL) {
        var components = URLComponents()
        components.scheme = Self.callbackScheme
        components.host = Self.relayHost
        components.queryItems = [
            URLQueryItem(name: "callback", value: callbackURL.absoluteString),
        ]
        finish(with: components.url)
    }

    private func relay(error: String) {
        var components = URLComponents()
        components.scheme = Self.callbackScheme
        components.host = Self.relayHost
        components.queryItems = [
            URLQueryItem(name: "error", value: error),
        ]
        finish(with: components.url)
    }

    private func finish(with relayURL: URL?) {
        guard !hasFinished else { return }
        hasFinished = true
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = nil
        if let relayURL {
            NSWorkspace.shared.open(relayURL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    private func scheduleAuthenticationTimeout() {
        authenticationTimeoutTask?.cancel()
        authenticationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !self.hasFinished else { return }
            Self.logger.error("Authentication helper timed out waiting for the system session")
            let session = self.authenticationSession
            self.authenticationSession = nil
            session?.cancel()
            self.relay(error: "timed_out")
        }
    }

    private func reactivateAfterSystemWindowAppears(for session: ASWebAuthenticationSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak session] in
            guard let self,
                  let session,
                  self.authenticationSession === session,
                  !self.hasFinished else {
                return
            }
            self.anchorWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private func makeAuthenticationCompletionHandler(
    for delegate: AuthenticationHelperDelegate
) -> ASWebAuthenticationSession.CompletionHandler {
    { [weak delegate] callbackURL, error in
        Task { @MainActor [weak delegate] in
            delegate?.authenticationDidComplete(callbackURL: callbackURL, error: error)
        }
    }
}

let app = NSApplication.shared
private let delegate = AuthenticationHelperDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
