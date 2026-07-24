import AppKit
import CryptoKit
import Foundation
import os
import Security

enum CandoaAccountKeychain {
    private static let service = "app.candoa.browser.Account"
    private static let account = "cloud-session"

    private static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
    }

    static var accessToken: String? {
        guard !isUITesting else { return nil }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new } as CFDictionary,
            &result
        )

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ accessToken: String) throws {
        let data = Data(accessToken.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(
                baseQuery.merging([
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
                ]) { _, new in new } as CFDictionary,
                nil
            )
            guard addStatus == errSecSuccess else { throw CandoaAccountError.keychainUnavailable }
            return
        }
        guard updateStatus == errSecSuccess else { throw CandoaAccountError.keychainUnavailable }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CandoaAccountError.keychainUnavailable
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct CandoaAccountStatus: Decodable, Sendable {
    let planID: String
    let allowedModelIDs: [String]

    var hasActiveSubscription: Bool {
        planID != "free" && !allowedModelIDs.isEmpty
    }
}

struct CandoaCloudSession: Decodable, Sendable {
    let user: CandoaCloudUser
}

struct CandoaCloudUser: Decodable, Sendable {
    let id: String
    let isAnonymous: Bool
}

enum CandoaCloudAPI {
    private static let defaultBaseURL = URL(string: "https://api.candoa.app/v1")!

    static var aiChatURL: URL {
        if let override = ProcessInfo.processInfo.environment["CANDOA_ASK_API_URL"],
           let url = URL(string: override) {
            return url
        }
        return endpoint("ai/chat")
    }

    static var aiAgentRunURL: URL {
        if let override = ProcessInfo.processInfo.environment["CANDOA_AGENT_API_URL"],
           let url = URL(string: override) {
            return url
        }
        if let chatOverride = ProcessInfo.processInfo.environment["CANDOA_ASK_API_URL"],
           let chatURL = URL(string: chatOverride) {
            return chatURL.deletingLastPathComponent().appending(path: "agent/run")
        }
        return endpoint("ai/agent/run")
    }

    static func session(accessToken: String) async throws -> CandoaCloudSession {
        let session: CandoaCloudSession? = try await request(
            endpoint("auth/get-session"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let session else {
            throw CandoaAccountError.server("Your Candoa session has expired.")
        }
        return session
    }

    static func signInAnonymously() async throws -> String {
        let (_, response) = try await dataRequest(
            endpoint("auth/sign-in/anonymous"),
            method: "POST",
            body: EmptyRequest(),
            accessToken: nil
        )
        guard let accessToken = response.value(forHTTPHeaderField: "set-auth-token"),
              !accessToken.isEmpty else {
            throw CandoaAccountError.invalidResponse
        }
        return accessToken
    }

    static func signOut(accessToken: String) async throws {
        let _: SignOutResponse = try await request(
            endpoint("auth/sign-out"),
            method: "POST",
            body: EmptyRequest(),
            accessToken: accessToken
        )
    }

    static func prepareAppleWebAuthentication(
        codeChallenge: String,
        callbackMode: String,
        accessToken: String?
    ) async throws -> URL {
        let response: AppleWebAuthenticationPrepareResponse = try await request(
            authenticationEndpoint("auth/apple/web/prepare"),
            method: "POST",
            body: AppleWebAuthenticationPrepareRequest(
                codeChallenge: codeChallenge,
                callbackMode: callbackMode
            ),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url), url.scheme == "https" else {
            throw CandoaAccountError.invalidResponse
        }
        return url
    }

    static func exchangeAppleWebAuthenticationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> String {
        let response: CandoaSessionResponse = try await request(
            authenticationEndpoint("auth/apple/web/exchange"),
            method: "POST",
            body: AppleWebAuthenticationExchangeRequest(code: code, codeVerifier: codeVerifier),
            accessToken: nil
        )
        return response.accessToken
    }

    static func accountStatus(accessToken: String) async throws -> CandoaAccountStatus {
        try await request(endpoint("account"), method: "GET", body: Optional<String>.none, accessToken: accessToken)
    }

    static func checkoutURL(accessToken: String, planID: String) async throws -> URL {
        let response: CandoaURLResponse = try await request(
            endpoint("billing/checkout"),
            method: "POST",
            body: BillingPlanRequest(planID: planID),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw CandoaAccountError.invalidResponse }
        return url
    }

    static func portalURL(accessToken: String) async throws -> URL {
        let response: CandoaURLResponse = try await request(
            endpoint("billing/portal"),
            method: "POST",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw CandoaAccountError.invalidResponse }
        return url
    }

    private static func endpoint(_ path: String) -> URL {
        let configuredBaseURL = ProcessInfo.processInfo.environment["CANDOA_CLOUD_API_URL"]
            .flatMap(URL.init(string:)) ?? defaultBaseURL
        return configuredBaseURL.appending(path: path)
    }

    private static func authenticationEndpoint(_ path: String) -> URL {
        // Apple requires a registered HTTPS callback. Keep web authentication on the
        // deployed Cloud service even when the rest of a Debug build uses local Cloud.
        let configuredBaseURL = ProcessInfo.processInfo.environment["CANDOA_APPLE_AUTH_API_URL"]
            .flatMap(URL.init(string:)) ?? defaultBaseURL
        return configuredBaseURL.appending(path: path)
    }

    private static func request<Body: Encodable, Response: Decodable>(
        _ url: URL,
        method: String,
        body: Body?,
        accessToken: String?
    ) async throws -> Response {
        let (data, _) = try await dataRequest(
            url,
            method: method,
            body: body,
            accessToken: accessToken
        )
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func dataRequest<Body: Encodable>(
        _ url: URL,
        method: String,
        body: Body?,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("candoa-auth://", forHTTPHeaderField: "Origin")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CandoaAccountError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder().decode(CandoaErrorResponse.self, from: data)
            throw CandoaAccountError.server(
                error?.error ?? error?.message ?? "Candoa could not complete that request."
            )
        }
        return (data, httpResponse)
    }

    private struct EmptyRequest: Encodable {}

    private struct AppleWebAuthenticationPrepareRequest: Encodable {
        let codeChallenge: String
        let callbackMode: String
    }

    private struct AppleWebAuthenticationPrepareResponse: Decodable {
        let url: String
    }

    private struct AppleWebAuthenticationExchangeRequest: Encodable {
        let code: String
        let codeVerifier: String
    }

    private struct CandoaSessionResponse: Decodable {
        let accessToken: String
    }

    private struct SignOutResponse: Decodable {
        let success: Bool
    }

    private struct BillingPlanRequest: Encodable {
        let planID: String
    }

    private struct CandoaURLResponse: Decodable {
        let url: String
    }

    private struct CandoaErrorResponse: Decodable {
        let error: String?
        let message: String?
    }
}

@MainActor
final class CandoaAppleWebAuthenticationService {
    private static let callbackScheme = "candoa-auth"
    private static let relayHost = "relay"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Candoa",
        category: "Account"
    )

    var isAuthenticating: Bool { CandoaAuthenticationRelay.shared.isWaiting }

    func authenticate(accessToken: String?) async throws -> String {
        guard !isAuthenticating else {
            throw CandoaAccountError.authenticationInProgress
        }

        let codeVerifier = try makeCodeVerifier()
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
        let callbackMode = "custom"
        Self.logger.info("Preparing Apple web authentication")
        let startURL: URL
        do {
            startURL = try await CandoaCloudAPI.prepareAppleWebAuthentication(
                codeChallenge: codeChallenge,
                callbackMode: callbackMode,
                accessToken: accessToken
            )
        } catch {
            Self.log(error, phase: "prepare")
            throw error
        }
        Self.logger.info("Starting the system Apple web authentication session")
        let callbackURL = try await authorizationCallbackURL(startURL: startURL)
        guard isExpectedCallbackURL(callbackURL) else {
            Self.logger.error(
                "Apple web authentication returned an unexpected callback location: scheme=\(callbackURL.scheme ?? "none", privacy: .public) host=\(callbackURL.host ?? "none", privacy: .public) path=\(callbackURL.path, privacy: .public)"
            )
            throw CandoaAccountError.appleSignInFailed
        }
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)

        if let callbackError = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            if callbackError == "cancelled" {
                Self.logger.info("Apple web authentication was cancelled")
                throw CandoaAccountError.appleSignInCancelled
            }
            Self.logger.error(
                "Apple web authentication callback failed: \(callbackError, privacy: .public)"
            )
            throw CandoaAccountError.appleCallback(callbackError)
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            Self.logger.error("Apple web authentication callback did not contain an exchange code")
            throw CandoaAccountError.appleSignInFailed
        }

        Self.logger.info("Exchanging the Apple web authentication code")
        do {
            return try await CandoaCloudAPI.exchangeAppleWebAuthenticationCode(
                code,
                codeVerifier: codeVerifier
            )
        } catch {
            Self.log(error, phase: "exchange")
            throw error
        }
    }

    static func handleAuthenticationRelay(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host?.lowercased() == relayHost else {
            return false
        }
        CandoaAuthenticationRelay.shared.receive(url)
        return true
    }

    private func authorizationCallbackURL(startURL: URL) async throws -> URL {
        try await CandoaAuthenticationRelay.shared.waitForCallback {
            let helperApplication = try await Self.launchAuthenticationHelper(startURL: startURL)
            Self.logger.info("The system Apple web authentication session started")
            return helperApplication
        }
    }

    private static func launchAuthenticationHelper(
        startURL: URL
    ) async throws -> NSRunningApplication {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("CandoaAuthenticationHelper.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            logger.error("The bundled Apple authentication helper is missing")
            throw CandoaAccountError.appleSignInCouldNotStart
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var launchComponents = URLComponents()
        launchComponents.scheme = "candoa-auth-helper-launch"
        launchComponents.host = "start"
        launchComponents.queryItems = [
            URLQueryItem(name: "url", value: startURL.absoluteString),
        ]
        guard let launchURL = launchComponents.url else {
            throw CandoaAccountError.appleSignInCouldNotStart
        }
        let logger = logger

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
            NSWorkspace.shared.open(
                [launchURL],
                withApplicationAt: helperURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    logger.error(
                        "The Apple authentication helper could not launch: \(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: CandoaAccountError.appleSignInCouldNotStart)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    logger.error("The Apple authentication helper launch returned no application")
                    continuation.resume(throwing: CandoaAccountError.appleSignInCouldNotStart)
                }
            }
        }
    }

    private static func log(_ error: any Error, phase: String) {
        let error = error as NSError
        logger.error(
            "Apple web authentication \(phase, privacy: .public) failed: domain=\(error.domain, privacy: .public) code=\(error.code) description=\(error.localizedDescription, privacy: .public)"
        )
    }

    private func isExpectedCallbackURL(_ callbackURL: URL) -> Bool {
        callbackURL.scheme?.lowercased() == Self.callbackScheme
            && callbackURL.host?.lowercased() == "callback"
    }

    private func makeCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CandoaAccountError.appleSignInFailed
        }
        return Data(bytes).base64URLEncodedString()
    }
}

@MainActor
private final class CandoaAuthenticationRelay {
    static let shared = CandoaAuthenticationRelay()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Candoa",
        category: "Account"
    )

    private var continuation: CheckedContinuation<URL, any Error>?
    private var helperMonitorTask: Task<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func waitForCallback(
        launch: @escaping @MainActor () async throws -> NSRunningApplication
    ) async throws -> URL {
        guard continuation == nil else {
            throw CandoaAccountError.authenticationInProgress
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, any Error>) in
            self.continuation = continuation
            Task { @MainActor in
                do {
                    let helperApplication = try await launch()
                    monitor(helperApplication)
                } catch {
                    finish(throwing: error)
                }
            }
        }
    }

    private func monitor(_ helperApplication: NSRunningApplication) {
        helperMonitorTask?.cancel()
        helperMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.continuation != nil {
                if helperApplication.isTerminated {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, self.continuation != nil else { return }
                    Self.logger.error(
                        "The Apple authentication helper exited before returning a callback"
                    )
                    self.finish(throwing: CandoaAccountError.appleSignInCouldNotStart)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func receive(_ relayURL: URL) {
        guard continuation != nil else { return }
        let components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        if let callback = components?.queryItems?.first(where: { $0.name == "callback" })?.value,
           let callbackURL = URL(string: callback) {
            finish(returning: callbackURL)
            return
        }

        let error = components?.queryItems?.first(where: { $0.name == "error" })?.value
        if error == "cancelled" {
            finish(throwing: CandoaAccountError.appleSignInCancelled)
        } else if error == "could_not_start" {
            finish(throwing: CandoaAccountError.appleSignInCouldNotStart)
        } else {
            finish(throwing: CandoaAccountError.appleSignInFailed)
        }
    }

    private func finish(returning callbackURL: URL) {
        let continuation = continuation
        self.continuation = nil
        helperMonitorTask?.cancel()
        helperMonitorTask = nil
        continuation?.resume(returning: callbackURL)
    }

    private func finish(throwing error: any Error) {
        let continuation = continuation
        self.continuation = nil
        helperMonitorTask?.cancel()
        helperMonitorTask = nil
        continuation?.resume(throwing: error)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct CandoaAccountService {
    var accessToken: String? { CandoaAccountKeychain.accessToken }

    func session(accessToken: String) async throws -> CandoaCloudSession {
        try await CandoaCloudAPI.session(accessToken: accessToken)
    }

    func signInAnonymously() async throws -> String {
        try await CandoaCloudAPI.signInAnonymously()
    }

    func signOut(accessToken: String) async throws {
        try await CandoaCloudAPI.signOut(accessToken: accessToken)
    }

    func saveAccessToken(_ accessToken: String) throws {
        try CandoaAccountKeychain.save(accessToken)
    }

    func removeAccessToken() throws {
        try CandoaAccountKeychain.remove()
    }

    func accountStatus(accessToken: String) async throws -> CandoaAccountStatus {
        try await CandoaCloudAPI.accountStatus(accessToken: accessToken)
    }

    func proCheckoutURL(accessToken: String) async throws -> URL {
        try await CandoaCloudAPI.checkoutURL(accessToken: accessToken, planID: "pro")
    }

    func billingPortalURL(accessToken: String) async throws -> URL {
        try await CandoaCloudAPI.portalURL(accessToken: accessToken)
    }
}

enum CandoaAccountError: LocalizedError, Sendable {
    case appleCallback(String)
    case appleSignInCancelled
    case appleSignInCouldNotStart
    case appleSignInFailed
    case authenticationInProgress
    case invalidResponse
    case keychainUnavailable
    case server(String)

    var isAuthenticationFailure: Bool {
        if case .server(let message) = self {
            return message.localizedCaseInsensitiveContains("session")
                || message.localizedCaseInsensitiveContains("authentication")
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .appleCallback(let error):
            switch error {
            case "cancelled":
                return nil
            case "expired":
                return "The Apple sign-in request expired. Please try again."
            case "session_expired":
                return "Your Candoa session expired. Please try signing in again."
            case "unavailable":
                return "Apple sign-in is temporarily unavailable. Please try again."
            case "invalid_request":
                return "Candoa received an invalid Apple sign-in response. Please try again."
            default:
                return "Apple sign-in was not completed. Please try again."
            }
        case .appleSignInCancelled:
            return nil
        case .appleSignInCouldNotStart:
            return "Candoa could not open Apple’s secure sign-in window. Please try again."
        case .appleSignInFailed:
            return "Apple sign-in was not completed. Please try again."
        case .authenticationInProgress:
            return "Apple sign-in is already in progress."
        case .invalidResponse:
            return "Candoa returned an invalid response."
        case .keychainUnavailable:
            return "Candoa could not save your session in Keychain."
        case .server(let message):
            return message
        }
    }
}
