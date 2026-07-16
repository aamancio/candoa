import AppKit
import AuthenticationServices
import Foundation
import Security
import SwiftUI

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSignedIn: Bool

    private let accountService: CandoaAccountService
    private var pendingAppleNonce: String?

    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }

    init(accountService: CandoaAccountService = CandoaAccountService()) {
        self.accountService = accountService
        isSignedIn = accountService.accessToken != nil
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_APPLE_SIGN_IN_WORKING"] == "1" {
            isWorking = true
        }
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
                let accessToken = try await accountService.authenticateWithApple(
                    identityToken: identityToken,
                    nonce: nonce
                )
                try accountService.saveAccessToken(accessToken)
                isSignedIn = true
                await refresh()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard let accessToken = accountService.accessToken else {
            status = nil
            isSignedIn = false
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            status = try await accountService.accountStatus(accessToken: accessToken)
            isSignedIn = true
            errorMessage = nil
        } catch {
            status = nil
            if (error as? CandoaAccountError)?.isAuthenticationFailure == true {
                try? accountService.removeAccessToken()
                isSignedIn = false
            }
            errorMessage = error.localizedDescription
        }
    }

    func startProCheckout() async {
        await openBillingURL { accessToken in
            try await accountService.proCheckoutURL(accessToken: accessToken)
        }
    }

    func openBillingPortal() async {
        await openBillingURL { accessToken in
            try await accountService.billingPortalURL(accessToken: accessToken)
        }
    }

    func signOut() {
        try? accountService.removeAccessToken()
        isSignedIn = false
        status = nil
        errorMessage = nil
    }

    private func openBillingURL(_ operation: (String) async throws -> URL) async {
        guard let accessToken = accountService.accessToken else {
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
