import Foundation
import OSLog
import Security

enum CandoaAccountKeychain {
    private static let service = "app.candoa.browser.Account"
    private static let account = "cloud-session"

    private static var isUITesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
#else
        false
#endif
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
    let hasAppleAccount: Bool
    let planID: String
    let allowedModelIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case hasAppleAccount
        case planID
        case allowedModelIDs
    }

    init(
        hasAppleAccount: Bool = false,
        planID: String,
        allowedModelIDs: [String]
    ) {
        self.hasAppleAccount = hasAppleAccount
        self.planID = planID
        self.allowedModelIDs = allowedModelIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasAppleAccount = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAppleAccount
        ) ?? false
        planID = try container.decode(String.self, forKey: .planID)
        allowedModelIDs = try container.decode(
            [String].self,
            forKey: .allowedModelIDs
        )
    }

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
    private static let logger = Logger(
        subsystem: "app.candoa.browser",
        category: "CloudAPI"
    )
    private static let productionBaseURL = URL(string: "https://www.candoa.app/api")!
    private static let developmentBaseURL = URL(string: "http://127.0.0.1:3000/api")!
    private static let developmentAppleAuthenticationBaseURL =
        URL(string: "https://candoa.a.pinggy.link/api")!

    private static var appleAuthenticationBaseURL: URL {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["CANDOA_APPLE_AUTH_BASE_URL"],
           let url = URL(string: value),
           url.scheme == "https",
           url.host(percentEncoded: false) != nil {
            return url
        }
        return developmentAppleAuthenticationBaseURL
#else
        return productionBaseURL
#endif
    }

    static var aiChatURL: URL {
        return endpoint("ai/chat")
    }

    static var aiAgentRunURL: URL {
        return endpoint("ai/agent")
    }

    static func session(accessToken: String) async throws -> CandoaCloudSession {
        let session: CandoaCloudSession? = try await request(
            endpoint("auth/get-session"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let session else {
            throw CandoaAccountError.sessionExpired
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

    static func appleSignInURL(accessToken: String?) async throws -> URL {
        let path = accessToken == nil
            ? "auth/native-apple/sign-in-intent"
            : "auth/native-apple/link-intent"
        let response: CandoaURLResponse = try await request(
            appleAuthenticationBaseURL.appending(path: path),
            method: "POST",
            body: EmptyRequest(),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else {
            logger.error("Apple authentication intent returned a malformed URL.")
            throw CandoaAccountError.invalidResponse
        }
        guard url.scheme == "https",
              url.host == appleAuthenticationBaseURL.host else {
            logger.error(
                """
                Apple authentication intent origin mismatch: \
                \(url.scheme ?? "nil", privacy: .public)://\
                \(url.host ?? "nil", privacy: .public), expected \
                \(appleAuthenticationBaseURL.scheme ?? "nil", privacy: .public)://\
                \(appleAuthenticationBaseURL.host ?? "nil", privacy: .public)
                """
            )
            throw CandoaAccountError.invalidResponse
        }
        return url
    }

    static func exchangeAppleSignInCode(_ code: String) async throws -> String {
        let (_, response) = try await dataRequest(
            appleAuthenticationBaseURL.appending(path: "auth/native-apple/exchange"),
            method: "POST",
            body: AppleCodeRequest(code: code),
            accessToken: nil
        )
        guard let accessToken = response.value(forHTTPHeaderField: "set-auth-token"),
              !accessToken.isEmpty else {
            throw CandoaAccountError.invalidResponse
        }
        return accessToken
    }

    static func accountStatus(accessToken: String) async throws -> CandoaAccountStatus {
        try await request(
            endpoint("account"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
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
        cloudBaseURL.appending(path: path)
    }

    private static var cloudBaseURL: URL {
#if DEBUG
        return environmentURL(key: "CANDOA_CLOUD_API_URL") ?? developmentBaseURL
#else
        // Release builds pin production: an inherited environment variable
        // must never be able to redirect account, billing, or AI traffic.
        return productionBaseURL
#endif
    }

#if DEBUG
    private static func environmentURL(key: String) -> URL? {
        let configuredURL = ProcessInfo.processInfo.environment[key]
            .flatMap(URL.init(string:))
        // Debug builds must never read or write production Cloud data. Apple
        // web authentication uses its separately configured registered HTTPS
        // endpoint; every ordinary API remains local.
        guard configuredURL?.host != productionBaseURL.host else {
            return nil
        }
        return configuredURL
    }
#endif

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
        request.setValue(origin(for: url), forHTTPHeaderField: "Origin")
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
            let message = error?.error ?? error?.message
                ?? "Candoa could not complete that request."
            if httpResponse.statusCode == 401 {
                throw CandoaAccountError.unauthorized(message)
            }
            throw CandoaAccountError.server(message)
        }
        return (data, httpResponse)
    }

    private static func origin(for url: URL) -> String {
        guard let scheme = url.scheme,
              let host = url.host else {
            return productionBaseURL.absoluteString
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private struct EmptyRequest: Encodable {}

    private struct SignOutResponse: Decodable {
        let success: Bool
    }

    private struct BillingPlanRequest: Encodable {
        let planID: String
    }

    private struct AppleCodeRequest: Encodable {
        let code: String
    }

    private struct CandoaURLResponse: Decodable {
        let url: String
    }

    private struct CandoaErrorResponse: Decodable {
        let error: String?
        let message: String?
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

    func appleSignInURL(accessToken: String?) async throws -> URL {
        try await CandoaCloudAPI.appleSignInURL(accessToken: accessToken)
    }

    func exchangeAppleSignInCode(_ code: String) async throws -> String {
        try await CandoaCloudAPI.exchangeAppleSignInCode(code)
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
    case appleAccountAlreadyLinked
    case invalidResponse
    case keychainUnavailable
    case sessionExpired
    case unauthorized(String)
    case server(String)

    var isAuthenticationFailure: Bool {
        switch self {
        case .sessionExpired, .unauthorized:
            return true
        case .appleAccountAlreadyLinked, .invalidResponse, .keychainUnavailable, .server:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .appleAccountAlreadyLinked:
            return "This Apple account is already connected to another Candoa account."
        case .invalidResponse:
            return "Candoa returned an invalid response."
        case .keychainUnavailable:
            return "Candoa could not save your session in Keychain."
        case .sessionExpired:
            return "Your Candoa session has expired."
        case .unauthorized(let message), .server(let message):
            return message
        }
    }
}
