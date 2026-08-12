import AppKit
import AuthenticationServices
import Foundation
import OSLog
import WebKit

/// The slice of `ASWebAuthenticationSessionRequest` the hosted-session
/// window needs. UI tests inject fixture requests through this seam because
/// real requests can only be minted by AuthenticationServices when Candoa is
/// the user's default browser — something a CI runner can never consent to.
protocol WebAuthenticationHostableRequest: AnyObject {
    var hostedRequestUUID: UUID { get }
    var hostedRequestURL: URL { get }
    var usesEphemeralSession: Bool { get }
    func matchesCallback(_ url: URL) -> Bool
    func completeHostedAuthentication(callbackURL: URL)
    func cancelHostedAuthentication(with error: any Error)
}

extension ASWebAuthenticationSessionRequest: WebAuthenticationHostableRequest {
    var hostedRequestUUID: UUID { uuid }
    var hostedRequestURL: URL { url }
    var usesEphemeralSession: Bool { shouldUseEphemeralSession }

    func matchesCallback(_ url: URL) -> Bool {
        if #available(macOS 14.4, *), let callback {
            return callback.matchesURL(url)
        }
        // Pre-14.4 requests carry only the (since-deprecated) scheme string.
        guard let scheme = legacyCallbackScheme, !scheme.isEmpty else { return false }
        return url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
    }

    func completeHostedAuthentication(callbackURL: URL) {
        complete(withCallbackURL: callbackURL)
    }

    func cancelHostedAuthentication(with error: any Error) {
        // This SDK imports `cancelWithError:` without splitting the label.
        cancelWithError(error)
    }

    private var legacyCallbackScheme: String? {
        // Routed through KVC so the deprecated `callbackURLScheme` accessor
        // doesn't trip deprecation diagnostics on every build; it remains the
        // only callback information a pre-14.4 request carries.
        value(forKey: "callbackURLScheme") as? String
    }
}

/// Hosts macOS system web-authentication sessions when Candoa is the default
/// browser: `ASWebAuthenticationSession` requests started by Candoa itself or
/// by any other app arrive through
/// `ASWebAuthenticationSessionWebBrowserSessionHandling` and are presented in
/// a dedicated native authentication window instead of bouncing to Safari.
///
/// Session pages deliberately never touch tabs, Spaces, history, restoration,
/// CloudKit, or hibernation: each request gets its own window and `WKWebView`
/// that no coordinator or store knows about, torn down the moment the
/// request completes or is canceled.
@MainActor
final class WebAuthenticationSessionHostService: NSObject {
    static let logger = Logger(
        subsystem: "app.candoa.browser",
        category: "WebAuthenticationHost"
    )

    /// Set by `activate()`. Candoa's own Sign in with Apple hosts its
    /// first-party session through this instance directly, bypassing the
    /// system's default-browser routing entirely (#253).
    private(set) static var shared: WebAuthenticationSessionHostService?

    private var activeSessions: [UUID: WebAuthenticationSessionWindowController] = [:]
    private var uiTestingRequestIDs: [String: UUID] = [:]

    func activate() {
        Self.shared = self
        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self
        configureUITestingRequestTriggers()
    }

    func hostFirstPartySession(_ request: FirstPartyWebAuthenticationRequest) {
        beginHosting(request)
    }

    fileprivate func beginHosting(_ request: any WebAuthenticationHostableRequest) {
        let uuid = request.hostedRequestUUID
        guard activeSessions[uuid] == nil else {
            Self.logger.error("Ignoring a duplicate web-authentication request.")
            return
        }
        Self.logger.notice(
            "Hosting a web-authentication session (ephemeral: \(request.usesEphemeralSession))."
        )
        let controller = WebAuthenticationSessionWindowController(request: request) {
            [weak self] finishedUUID in
            self?.activeSessions.removeValue(forKey: finishedUUID)
            self?.uiTestingRequestIDs = self?.uiTestingRequestIDs.filter {
                $0.value != finishedUUID
            } ?? [:]
        }
        activeSessions[uuid] = controller
        controller.present()
    }

    fileprivate func cancelWithoutResolving(requestUUID: UUID) {
        // The requesting app canceled its session; AuthenticationServices
        // only expects the browser UI to disappear, not a completion.
        activeSessions[requestUUID]?.dismissWithoutResolving()
    }

    // MARK: - UI-testing seam

    /// Distributed-notification triggers standing in for the system: real
    /// `ASWebAuthenticationSessionRequest`s cannot be constructed in tests,
    /// and routing real ones requires default-browser consent no runner can
    /// grant. Payloads: begin = "id|url|callbackScheme|shared-or-ephemeral",
    /// cancel = "id". Outcomes surface through `ui-testing-state`'s
    /// `webAuth=` field via `uiTestingWebAuthEventNotification`.
    nonisolated static let uiTestingBeginNotification =
        Notification.Name("app.candoa.uitesting.web-auth-begin")
    nonisolated static let uiTestingCancelNotification =
        Notification.Name("app.candoa.uitesting.web-auth-cancel")
    nonisolated static let uiTestingWebAuthEventNotification =
        Notification.Name("app.candoa.uitesting.web-auth-event")

    private func configureUITestingRequestTriggers() {
        guard BrowserStore.isUITesting else { return }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.uiTestingBeginNotification,
            object: nil,
            queue: .main
        ) { notification in
            let payload = notification.object as? String ?? ""
            Task { @MainActor [weak self] in
                self?.beginUITestingRequest(payload: payload)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.uiTestingCancelNotification,
            object: nil,
            queue: .main
        ) { notification in
            let payload = notification.object as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self, let uuid = self.uiTestingRequestIDs[payload] else { return }
                self.cancelWithoutResolving(requestUUID: uuid)
                Self.postUITestingEvent("\(payload):dismissed")
            }
        }
    }

    private func beginUITestingRequest(payload: String) {
        let parts = payload.split(separator: "|").map(String.init)
        guard parts.count == 4, let url = URL(string: parts[1]) else { return }
        let request = UITestingWebAuthenticationRequest(
            testID: parts[0],
            url: url,
            callbackScheme: parts[2],
            usesEphemeralSession: parts[3] == "ephemeral"
        )
        uiTestingRequestIDs[parts[0]] = request.hostedRequestUUID
        Self.postUITestingEvent(
            "\(parts[0]):began:\(parts[3] == "ephemeral" ? "ephemeral" : "shared")"
        )
        beginHosting(request)
    }

    nonisolated static func postUITestingEvent(_ event: String) {
        // BrowserStore.isUITesting is main-actor bound; this event path must
        // stay callable from the nonisolated fake-request hooks.
#if DEBUG
        let isUITesting = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
#else
        let isUITesting = false
#endif
        guard isUITesting else { return }
        NotificationCenter.default.post(
            name: uiTestingWebAuthEventNotification,
            object: event
        )
    }
}

extension WebAuthenticationSessionHostService: ASWebAuthenticationSessionWebBrowserSessionHandling {
    nonisolated func begin(_ request: ASWebAuthenticationSessionRequest) {
        // The system hands the request over entirely — nothing else holds it
        // on the calling thread, so moving it to the main actor is safe.
        nonisolated(unsafe) let request = request
        Task { @MainActor in
            self.beginHosting(request)
        }
    }

    nonisolated func cancel(_ request: ASWebAuthenticationSessionRequest) {
        let uuid = request.uuid
        Task { @MainActor in
            self.cancelWithoutResolving(requestUUID: uuid)
        }
    }
}

/// One hosted session: a dedicated titled window holding a solitary
/// `WKWebView`. Completes its request only on a main-frame navigation the
/// request's own callback matcher accepts; everything else — window close,
/// system cancellation, fatal load errors — resolves exactly once with the
/// appropriate error, then tears the web view and window down.
@MainActor
final class WebAuthenticationSessionWindowController: NSObject {
    private let request: any WebAuthenticationHostableRequest
    private let onFinish: (UUID) -> Void
    private var window: NSWindow?
    private var webView: WKWebView?
    private var hasResolved = false

    init(
        request: any WebAuthenticationHostableRequest,
        onFinish: @escaping (UUID) -> Void
    ) {
        self.request = request
        self.onFinish = onFinish
        super.init()
    }

    func present() {
        let configuration = WKWebViewConfiguration()
        // Ephemeral requests leave no reusable website data: the
        // non-persistent store lives and dies with this web view. Shared
        // requests use WebKit's default persistent store so providers see
        // the cookies a browser-level session is expected to share.
        configuration.websiteDataStore = request.usesEphemeralSession
            ? .nonPersistent()
            : .default()
        configuration.applicationNameForUserAgent =
            WebViewCoordinator.browserUserAgentApplicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: request.hostedRequestURL)
        window.identifier = NSUserInterfaceItemIdentifier("web-auth-window")
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        load(request.hostedRequestURL, in: webView)
    }

    func dismissWithoutResolving() {
        hasResolved = true
        close()
    }

    private static func windowTitle(for url: URL) -> String {
        guard let host = url.host else {
            return String(localized: "Sign In")
        }
        return String(localized: "Sign In — \(host)")
    }

    private func load(_ url: URL, in webView: WKWebView) {
        // UI-test fixture pages load inline: the fixture host resolves
        // nowhere, and hosted-session web views bypass WebViewCoordinator's
        // fixture handling on purpose (they must never join the tab world).
        if BrowserStore.isUITesting,
           url.host == "fixture.candoa.test",
           let fixtureHTML = ProcessInfo.processInfo
               .environment["CANDOA_UI_TESTING_PAGE_HTML"] {
            webView.loadHTMLString(fixtureHTML, baseURL: url)
            return
        }
        webView.load(URLRequest(url: url))
    }

    private func resolveCompleted(callbackURL: URL) {
        guard !hasResolved else { return }
        hasResolved = true
        WebAuthenticationSessionHostService.logger.notice(
            "Hosted web-authentication session completed with a matching callback."
        )
        request.completeHostedAuthentication(callbackURL: callbackURL)
        close()
    }

    private func resolveCanceled(with error: any Error) {
        guard !hasResolved else { return }
        hasResolved = true
        let nsError = error as NSError
        WebAuthenticationSessionHostService.logger.notice(
            "Hosted web-authentication session canceled: \(nsError.domain, privacy: .public) \(nsError.code)."
        )
        request.cancelHostedAuthentication(with: error)
        close()
    }

    private func close() {
        guard let window else {
            tearDown()
            return
        }
        // Break the delegate loop first: close() fires windowWillClose,
        // which must not re-resolve or re-close.
        window.delegate = nil
        self.window = nil
        window.close()
        tearDown()
    }

    /// Nothing of the session survives: the web view stops, leaves the
    /// window, and drops its delegate so the only remaining owner (this
    /// controller) is released by the service's finish callback.
    private func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        onFinish(request.hostedRequestUUID)
    }

    private static var canceledLoginError: NSError {
        NSError(
            domain: ASWebAuthenticationSessionError.errorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        )
    }
}

extension WebAuthenticationSessionWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // The window is already tearing itself down — drop the reference so
        // resolveCanceled's close() doesn't re-close it mid-flight. The user
        // dismissed it; the requesting app receives the standard
        // canceled-login error.
        window?.delegate = nil
        window = nil
        resolveCanceled(with: Self.canceledLoginError)
    }
}

extension WebAuthenticationSessionWindowController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow)
            return
        }

        // Only the request's own matcher completes the session — never a
        // lookalike scheme or host.
        if request.matchesCallback(url) {
            decisionHandler(.cancel)
            resolveCompleted(callbackURL: url)
            return
        }

        // A non-matching custom scheme can't render in the web view and
        // must not escape to another app from an authentication surface.
        if let scheme = url.scheme?.lowercased(),
           !["http", "https", "about"].contains(scheme) {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        handleNavigationFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        handleNavigationFailure(error)
    }

    private func handleNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        // Deliberate policy cancellations and mid-flight interruptions are
        // not provider failures.
        guard nsError.code != NSURLErrorCancelled || nsError.domain != NSURLErrorDomain else {
            return
        }
        // Legacy WebKit domain: policy-cancelled frame loads (code 102)
        // surface here when the callback navigation is intercepted.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
            return
        }
        // A provider that cannot load leaves nothing to authenticate
        // against; hand the real error back to the requesting app.
        resolveCanceled(with: error)
    }
}

/// First-party request minted by Candoa's own Sign in with Apple flow. The
/// session never touches `ASWebAuthenticationSession`, so no default browser
/// (or its Safari fallback) can intercept it — it always lands in the
/// dedicated Sign In window. Uses the shared website data store, matching the
/// non-ephemeral session the previous system-routed flow requested.
final class FirstPartyWebAuthenticationRequest: WebAuthenticationHostableRequest {
    let hostedRequestUUID = UUID()
    let hostedRequestURL: URL
    let usesEphemeralSession = false
    private let callbackScheme: String
    private let onComplete: @MainActor @Sendable (URL) -> Void
    private let onCancel: @MainActor @Sendable (any Error) -> Void

    init(
        url: URL,
        callbackScheme: String,
        onComplete: @escaping @MainActor @Sendable (URL) -> Void,
        onCancel: @escaping @MainActor @Sendable (any Error) -> Void
    ) {
        self.hostedRequestURL = url
        self.callbackScheme = callbackScheme
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    func matchesCallback(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame
    }

    func completeHostedAuthentication(callbackURL: URL) {
        // Resolutions come from the main-actor window controller.
        MainActor.assumeIsolated { [onComplete] in onComplete(callbackURL) }
    }

    func cancelHostedAuthentication(with error: any Error) {
        MainActor.assumeIsolated { [onCancel] in onCancel(error) }
    }
}

/// Stand-in request minted by the UI-testing triggers. Matches callbacks by
/// scheme, mirroring a custom-scheme `ASWebAuthenticationSession.Callback`.
private final class UITestingWebAuthenticationRequest: WebAuthenticationHostableRequest {
    let hostedRequestUUID = UUID()
    let hostedRequestURL: URL
    let usesEphemeralSession: Bool
    private let testID: String
    private let callbackScheme: String

    init(testID: String, url: URL, callbackScheme: String, usesEphemeralSession: Bool) {
        self.testID = testID
        self.hostedRequestURL = url
        self.callbackScheme = callbackScheme
        self.usesEphemeralSession = usesEphemeralSession
    }

    func matchesCallback(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame
    }

    func completeHostedAuthentication(callbackURL: URL) {
        WebAuthenticationSessionHostService.postUITestingEvent(
            "\(testID):resolved-completed:\(callbackURL.absoluteString)"
        )
    }

    func cancelHostedAuthentication(with error: any Error) {
        let nsError = error as NSError
        WebAuthenticationSessionHostService.postUITestingEvent(
            "\(testID):resolved-canceled:\(nsError.domain):\(nsError.code)"
        )
    }
}
