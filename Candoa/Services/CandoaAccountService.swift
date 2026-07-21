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

    static func authenticateWithApple(identityToken: String, nonce: String) async throws -> String {
        let response: CandoaSessionResponse = try await request(
            endpoint("auth/apple"),
            method: "POST",
            body: AppleAuthenticationRequest(identityToken: identityToken, nonce: nonce),
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

    private static func request<Body: Encodable, Response: Decodable>(
        _ url: URL,
        method: String,
        body: Body?,
        accessToken: String?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            throw CandoaAccountError.server(error?.error ?? "Candoa could not complete that request.")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private struct AppleAuthenticationRequest: Encodable {
        let identityToken: String
        let nonce: String
    }

    private struct CandoaSessionResponse: Decodable {
        let accessToken: String
    }

    private struct BillingPlanRequest: Encodable {
        let planID: String
    }

    private struct CandoaURLResponse: Decodable {
        let url: String
    }

    private struct CandoaErrorResponse: Decodable {
        let error: String?
    }
}

struct CandoaAccountService {
    var accessToken: String? { CandoaAccountKeychain.accessToken }

    func authenticateWithApple(identityToken: String, nonce: String) async throws -> String {
        try await CandoaCloudAPI.authenticateWithApple(identityToken: identityToken, nonce: nonce)
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

enum CandoaAccountError: LocalizedError {
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
        case .invalidResponse:
            return "Candoa returned an invalid response."
        case .keychainUnavailable:
            return "Candoa could not save your session in Keychain."
        case .server(let message):
            return message
        }
    }
}
