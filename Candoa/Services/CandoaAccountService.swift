import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
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
            authenticationEndpoint("auth/get-session"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let session else {
            throw CandoaAccountError.server("Your Candoa session has expired.")
        }
        return session
    }

    static func signOut(accessToken: String) async throws {
        let _: SignOutResponse = try await request(
            authenticationEndpoint("auth/sign-out"),
            method: "POST",
            body: EmptyRequest(),
            accessToken: accessToken
        )
    }

    static func prepareAppleWebAuthentication(
        codeChallenge: String,
        accessToken: String?
    ) async throws -> URL {
        let response: AppleWebAuthenticationPrepareResponse = try await request(
            authenticationEndpoint("auth/apple/web/prepare"),
            method: "POST",
            body: AppleWebAuthenticationPrepareRequest(codeChallenge: codeChallenge),
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
final class CandoaAppleWebAuthenticationService: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    private static let callbackScheme = "candoa-auth"

    private var webAuthenticationSession: ASWebAuthenticationSession?

    var isAuthenticating: Bool { webAuthenticationSession != nil }

    func authenticate(accessToken: String?) async throws -> String {
        guard webAuthenticationSession == nil else {
            throw CandoaAccountError.authenticationInProgress
        }

        let codeVerifier = try makeCodeVerifier()
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
        let startURL = try await CandoaCloudAPI.prepareAppleWebAuthentication(
            codeChallenge: codeChallenge,
            accessToken: accessToken
        )
        let callbackURL = try await authorizationCallbackURL(startURL: startURL)
        guard callbackURL.scheme?.lowercased() == Self.callbackScheme,
              callbackURL.host?.lowercased() == "callback" else {
            throw CandoaAccountError.appleSignInFailed
        }
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)

        if components?.queryItems?.first(where: { $0.name == "error" })?.value == "cancelled" {
            throw CandoaAccountError.appleSignInCancelled
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw CandoaAccountError.appleSignInFailed
        }

        return try await CandoaCloudAPI.exchangeAppleWebAuthenticationCode(
            code,
            codeVerifier: codeVerifier
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
    }

    private func authorizationCallbackURL(startURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completionHandler: ASWebAuthenticationSession.CompletionHandler = {
                @Sendable [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.webAuthenticationSession = nil
                    let authenticationError = error as NSError?
                    if authenticationError?.domain == ASWebAuthenticationSessionError.errorDomain,
                       authenticationError?.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                        continuation.resume(throwing: CandoaAccountError.appleSignInCancelled)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: CandoaAccountError.appleSignInFailed)
                    }
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                session = ASWebAuthenticationSession(
                    url: startURL,
                    callback: .customScheme(Self.callbackScheme),
                    completionHandler: completionHandler
                )
            } else {
                session = ASWebAuthenticationSession(
                    url: startURL,
                    callbackURLScheme: Self.callbackScheme,
                    completionHandler: completionHandler
                )
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session
            guard session.start() else {
                webAuthenticationSession = nil
                continuation.resume(throwing: CandoaAccountError.appleSignInFailed)
                return
            }
        }
    }

    private func makeCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CandoaAccountError.appleSignInFailed
        }
        return Data(bytes).base64URLEncodedString()
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
    case appleSignInCancelled
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
        case .appleSignInCancelled:
            return nil
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
