import Foundation
import OSLog
import Security

/// Generic-password storage backed by the data-protection keychain, where
/// access is granted by the app's keychain access group — identical across
/// Debug and Release builds — instead of the legacy login keychain's
/// per-binary signature ACL, which shows a password prompt whenever a
/// differently signed build touches the item (issue #120). Items written by
/// older versions into the legacy login keychain are migrated on the first
/// read that can complete without user interaction.
struct KeychainStore {
    let service: String
    let account: String

    func read() -> String? {
        if let value = copyValue(query(dataProtection: true)) { return value }
        return migrateLegacyItem()
    }

    func save(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query(dataProtection: true) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var attributes = query(dataProtection: true)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func remove() -> OSStatus {
        let status = SecItemDelete(query(dataProtection: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return status }

        withoutKeychainInteraction {
            _ = SecItemDelete(query(dataProtection: false) as CFDictionary)
        }
        return errSecSuccess
    }

    private func migrateLegacyItem() -> String? {
        let value = withoutKeychainInteraction {
            copyValue(query(dataProtection: false))
        }
        guard let value else { return nil }

        if save(value) == errSecSuccess {
            withoutKeychainInteraction {
                _ = SecItemDelete(query(dataProtection: false) as CFDictionary)
            }
        }
        return value
    }

    private func copyValue(_ query: [String: Any]) -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new } as CFDictionary,
            &result
        )

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Legacy login-keychain items are guarded by a per-binary ACL; touching
    /// one from a build the ACL doesn't trust would show the very password
    /// prompt this store exists to avoid. With interaction disabled the call
    /// fails silently instead, and migration waits for a trusted binary.
    private func withoutKeychainInteraction<T>(_ body: () -> T) -> T {
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

enum AccountKeychain {
    private static let store = KeychainStore(
        service: "app.candoa.browser.Account",
        account: "cloud-session"
    )

    private static var isUITesting: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
#else
        false
#endif
    }

    static var accessToken: String? {
        guard !isUITesting else { return nil }
        return store.read()
    }

    static func save(_ accessToken: String) throws {
        guard store.save(accessToken) == errSecSuccess else {
            throw AccountError.keychainUnavailable
        }
    }

    static func remove() throws {
        guard store.remove() == errSecSuccess else {
            throw AccountError.keychainUnavailable
        }
    }
}

struct AccountStatus: Decodable, Sendable {
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

struct CloudSession: Decodable, Sendable {
    let user: CloudUser
}

struct CloudUser: Decodable, Sendable {
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

enum CloudAPI {
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

    /// The plan-filtered hosted model catalog. The server stays authoritative
    /// for availability and credit cost; the client only adds display and
    /// budgeting metadata.
    static func hostedAIModels(accessToken: String) async throws -> [AIModel] {
        let response: HostedModelsResponse = try await request(
            endpoint("ai/models"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        return response.models.map { model in
            AIModelCatalog.hostedModel(
                id: model.id,
                providerID: model.providerID,
                displayName: model.displayName
            )
        }
    }

    private struct HostedModelsResponse: Decodable {
        let models: [HostedModelEntry]
    }

    private struct HostedModelEntry: Decodable {
        let id: String
        let providerID: String
        let displayName: String
    }

    static var aiAgentRunURL: URL {
        return endpoint("ai/agent")
    }

    static func session(accessToken: String) async throws -> CloudSession {
        let session: CloudSession? = try await request(
            endpoint("auth/get-session"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let session else {
            throw AccountError.sessionExpired
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
            throw AccountError.invalidResponse
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
        let response: CloudURLResponse = try await request(
            appleAuthenticationBaseURL.appending(path: path),
            method: "POST",
            body: EmptyRequest(),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else {
            logger.error("Apple authentication intent returned a malformed URL.")
            throw AccountError.invalidResponse
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
            throw AccountError.invalidResponse
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
            throw AccountError.invalidResponse
        }
        return accessToken
    }

    static func accountStatus(accessToken: String) async throws -> AccountStatus {
        try await request(
            endpoint("account"),
            method: "GET",
            body: Optional<String>.none,
            accessToken: accessToken
        )
    }

    static func checkoutURL(accessToken: String, planID: String) async throws -> URL {
        let response: CloudURLResponse = try await request(
            endpoint("billing/checkout"),
            method: "POST",
            body: BillingPlanRequest(planID: planID),
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw AccountError.invalidResponse }
        return url
    }

    static func portalURL(accessToken: String) async throws -> URL {
        let response: CloudURLResponse = try await request(
            endpoint("billing/portal"),
            method: "POST",
            body: Optional<String>.none,
            accessToken: accessToken
        )
        guard let url = URL(string: response.url) else { throw AccountError.invalidResponse }
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
            throw AccountError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder().decode(CloudErrorResponse.self, from: data)
            let message = error?.error ?? error?.message
                ?? "Candoa could not complete that request."
            if httpResponse.statusCode == 401 {
                throw AccountError.unauthorized(message)
            }
            throw AccountError.server(message)
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

    private struct CloudURLResponse: Decodable {
        let url: String
    }

    private struct CloudErrorResponse: Decodable {
        let error: String?
        let message: String?
    }
}

struct AccountService {
    var accessToken: String? { AccountKeychain.accessToken }

    func session(accessToken: String) async throws -> CloudSession {
        try await CloudAPI.session(accessToken: accessToken)
    }

    func signInAnonymously() async throws -> String {
        try await CloudAPI.signInAnonymously()
    }

    func signOut(accessToken: String) async throws {
        try await CloudAPI.signOut(accessToken: accessToken)
    }

    func appleSignInURL(accessToken: String?) async throws -> URL {
        try await CloudAPI.appleSignInURL(accessToken: accessToken)
    }

    func exchangeAppleSignInCode(_ code: String) async throws -> String {
        try await CloudAPI.exchangeAppleSignInCode(code)
    }

    func saveAccessToken(_ accessToken: String) throws {
        try AccountKeychain.save(accessToken)
    }

    func removeAccessToken() throws {
        try AccountKeychain.remove()
    }

    func accountStatus(accessToken: String) async throws -> AccountStatus {
        try await CloudAPI.accountStatus(accessToken: accessToken)
    }

    func hostedAIModels(accessToken: String) async throws -> [AIModel] {
        try await CloudAPI.hostedAIModels(accessToken: accessToken)
    }

    func proCheckoutURL(accessToken: String) async throws -> URL {
        try await CloudAPI.checkoutURL(accessToken: accessToken, planID: "pro")
    }

    func billingPortalURL(accessToken: String) async throws -> URL {
        try await CloudAPI.portalURL(accessToken: accessToken)
    }
}

enum AccountError: LocalizedError, Sendable {
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
