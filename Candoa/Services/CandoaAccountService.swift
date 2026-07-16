import AuthenticationServices
import AppKit
import Foundation
import Security
import SwiftUI

enum CandoaAccountKeychain {
    private static let service = "app.candoa.Candoa.Account"
    private static let account = "cloud-session"

    static var accessToken: String? {
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
    private static let defaultBaseURL = URL(string: "https://api.candoa.com/v1")!

    static var aiChatURL: URL {
        if let override = ProcessInfo.processInfo.environment["CANDOA_ASK_API_URL"],
           let url = URL(string: override) {
            return url
        }
        return endpoint("ai/chat")
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

@MainActor
final class CandoaAccountController: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSignedIn: Bool

    private var pendingAppleNonce: String?

    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }

    init() {
        isSignedIn = CandoaAccountKeychain.accessToken != nil
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        pendingAppleNonce = makeNonce()
        request.requestedScopes = [.email, .fullName]
        request.nonce = pendingAppleNonce
        errorMessage = nil
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              let nonce = pendingAppleNonce else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            errorMessage = "Apple sign-in was not completed. Please try again."
            return
        }

        pendingAppleNonce = nil
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let accessToken = try await CandoaCloudAPI.authenticateWithApple(
                    identityToken: identityToken,
                    nonce: nonce
                )
                try CandoaAccountKeychain.save(accessToken)
                isSignedIn = true
                await refresh()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard let accessToken = CandoaAccountKeychain.accessToken else {
            status = nil
            isSignedIn = false
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            status = try await CandoaCloudAPI.accountStatus(accessToken: accessToken)
            errorMessage = nil
        } catch {
            status = nil
            if (error as? CandoaAccountError)?.isAuthenticationFailure == true {
                try? CandoaAccountKeychain.remove()
                isSignedIn = false
            }
            errorMessage = error.localizedDescription
        }
    }

    func startProCheckout() async {
        await openBillingURL { accessToken in
            try await CandoaCloudAPI.checkoutURL(accessToken: accessToken, planID: "pro")
        }
    }

    func openBillingPortal() async {
        await openBillingURL { accessToken in
            try await CandoaCloudAPI.portalURL(accessToken: accessToken)
        }
    }

    func signOut() {
        try? CandoaAccountKeychain.remove()
        isSignedIn = false
        status = nil
        errorMessage = nil
    }

    private func openBillingURL(_ operation: (String) async throws -> URL) async {
        guard let accessToken = CandoaAccountKeychain.accessToken else {
            errorMessage = "Sign in with Apple before managing Candoa billing."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            NSWorkspace.shared.open(try await operation(accessToken))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum CandoaAccountError: LocalizedError {
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
