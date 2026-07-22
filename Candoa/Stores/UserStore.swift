import AppKit
import Foundation
import SwiftUI

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSignedIn: Bool

    private let accountService: CandoaAccountService
    private let appleAuthenticationService: CandoaAppleWebAuthenticationService

    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }

    init(
        accountService: CandoaAccountService = CandoaAccountService(),
        appleAuthenticationService: CandoaAppleWebAuthenticationService =
            CandoaAppleWebAuthenticationService()
    ) {
        self.accountService = accountService
        self.appleAuthenticationService = appleAuthenticationService
        isSignedIn = false
        let environment = ProcessInfo.processInfo.environment
        isWorking = environment["CANDOA_UI_TESTING"] == "1"
            ? environment["CANDOA_UI_TESTING_APPLE_SIGN_IN_WORKING"] == "1"
            : accountService.accessToken != nil
    }

    func restoreSessionIfNeeded() async {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        guard accountService.accessToken != nil else {
            isWorking = false
            isSignedIn = false
            return
        }
        await refresh()
    }

    func signInWithApple() {
        guard !isWorking, !appleAuthenticationService.isAuthenticating else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let accessToken = try await appleAuthenticationService.authenticate()
                try accountService.saveAccessToken(accessToken)
                isSignedIn = true
                await refresh()
            } catch {
                isWorking = false
                if case CandoaAccountError.appleSignInCancelled = error {
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
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
}
