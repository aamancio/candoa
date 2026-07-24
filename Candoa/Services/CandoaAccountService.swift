import AppKit
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
    let isAnonymous: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case isAnonymous
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        isAnonymous = try container.decodeIfPresent(Bool.self, forKey: .isAnonymous) ?? false
    }
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
            accountEndpoint("auth/get-session"),
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
            accountEndpoint("auth/sign-in/anonymous"),
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
            accountEndpoint("auth/sign-out"),
            method: "POST",
            body: EmptyRequest(),
            accessToken: accessToken
        )
    }

    static func prepareEmailRecovery(
        email: String,
        codeChallenge: String
    ) async throws {
        let _: EmailRecoveryPrepareResponse = try await request(
            accountEndpoint("auth/email/recovery/prepare"),
            method: "POST",
            body: EmailRecoveryPrepareRequest(
                email: email,
                codeChallenge: codeChallenge
            ),
            accessToken: nil
        )
    }

    static func exchangeEmailRecoveryCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> String {
        let response: CandoaSessionResponse = try await request(
            accountEndpoint("auth/email/recovery/exchange"),
            method: "POST",
            body: EmailRecoveryExchangeRequest(code: code, codeVerifier: codeVerifier),
            accessToken: nil
        )
        return response.accessToken
    }

    static func accountStatus(accessToken: String) async throws -> CandoaAccountStatus {
        try await request(
            accountEndpoint("account"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    static func checkoutURL(accessToken: String, planID: String) async throws -> URL {
        let response: CandoaURLResponse = try await request(
            accountEndpoint("billing/checkout"),
            method: "POST",
            body: BillingPlanRequest(planID: planID),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw CandoaAccountError.invalidResponse }
        return url
    }

    static func portalURL(accessToken: String) async throws -> URL {
        let response: CandoaURLResponse = try await request(
            accountEndpoint("billing/portal"),
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

    private static func accountEndpoint(_ path: String) -> URL {
        // Authentication, session validation, account state, and billing must share
        // one authority. A production-issued session cannot be validated by a local
        // Cloud instance with a different database and signing secret.
        let configuredBaseURL = ProcessInfo.processInfo.environment["CANDOA_ACCOUNT_API_URL"]
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

    private struct EmailRecoveryPrepareRequest: Encodable {
        let email: String
        let codeChallenge: String
    }

    private struct EmailRecoveryPrepareResponse: Decodable {
        let success: Bool
    }

    private struct EmailRecoveryExchangeRequest: Encodable {
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
final class CandoaEmailRecoveryService {
    private static let callbackScheme = "candoa-auth"
    private static let callbackHost = "email-recovery"

    var isRecovering: Bool { CandoaEmailRecoveryRelay.shared.isWaiting }

    func restoreSubscription(email: String) async throws -> String {
        guard !isRecovering else {
            throw CandoaAccountError.recoveryInProgress
        }

        let codeVerifier = try makeCodeVerifier()
        let codeChallenge = Data(SHA256.hash(data: Data(codeVerifier.utf8)))
            .base64URLEncodedString()
        try await CandoaCloudAPI.prepareEmailRecovery(
            email: email,
            codeChallenge: codeChallenge
        )
        let callbackURL = try await CandoaEmailRecoveryRelay.shared.waitForCallback()
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)

        if let callbackError = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw CandoaAccountError.recoveryFailed(callbackError)
        }
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw CandoaAccountError.recoveryFailed("invalid")
        }
        return try await CandoaCloudAPI.exchangeEmailRecoveryCode(
            code,
            codeVerifier: codeVerifier
        )
    }

    static func handleRecoveryURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == callbackScheme,
              url.host?.lowercased() == callbackHost else {
            return false
        }
        CandoaEmailRecoveryRelay.shared.receive(url)
        return true
    }

    private func makeCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CandoaAccountError.recoveryFailed("unavailable")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

@MainActor
private final class CandoaEmailRecoveryRelay {
    static let shared = CandoaEmailRecoveryRelay()

    private var continuation: CheckedContinuation<URL, any Error>?
    private var timeoutTask: Task<Void, Never>?

    var isWaiting: Bool { continuation != nil }

    func waitForCallback() async throws -> URL {
        guard continuation == nil else {
            throw CandoaAccountError.recoveryInProgress
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, any Error>) in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, let self, self.continuation != nil else { return }
                self.finish(throwing: CandoaAccountError.recoveryFailed("expired"))
            }
        }
    }

    func receive(_ url: URL) {
        guard continuation != nil else { return }
        finish(returning: url)
    }

    private func finish(returning url: URL) {
        let continuation = continuation
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: url)
    }

    private func finish(throwing error: any Error) {
        let continuation = continuation
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
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
    case invalidResponse
    case keychainUnavailable
    case recoveryFailed(String)
    case recoveryInProgress
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
        case .invalidResponse:
            return "Candoa returned an invalid response."
        case .keychainUnavailable:
            return "Candoa could not save your session in Keychain."
        case .recoveryFailed(let reason):
            switch reason {
            case "expired", "invalid":
                return "That recovery link expired. Please request a new one."
            case "unavailable":
                return "Subscription recovery is temporarily unavailable."
            default:
                return "Candoa could not restore your subscription. Please try again."
            }
        case .recoveryInProgress:
            return "Check your email to finish restoring your subscription."
        case .server(let message):
            return message
        }
    }
}
