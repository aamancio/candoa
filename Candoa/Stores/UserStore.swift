import AppKit
import Foundation
import SwiftUI

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var hasCloudSession: Bool
    @Published private(set) var isLocalOnly: Bool
    @Published private(set) var hasCompletedAccountChoice: Bool

    private let accountService: CandoaAccountService
    private let appleAuthenticationService: CandoaAppleWebAuthenticationService

    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }

    static var hasStoredAccountChoice: Bool {
        UserDefaults.standard.bool(forKey: accountChoiceKey)
    }

    private static let accountChoiceKey = "Candoa.HasCompletedAccountChoice"

    init(
        accountService: CandoaAccountService = CandoaAccountService(),
        appleAuthenticationService: CandoaAppleWebAuthenticationService =
            CandoaAppleWebAuthenticationService()
    ) {
        self.accountService = accountService
        self.appleAuthenticationService = appleAuthenticationService
        let hasStoredToken = accountService.accessToken != nil
        isSignedIn = false
        hasCloudSession = hasStoredToken
        isLocalOnly = false
        hasCompletedAccountChoice = hasStoredToken || Self.hasStoredAccountChoice
        let environment = ProcessInfo.processInfo.environment
        isWorking = environment["CANDOA_UI_TESTING"] == "1"
            ? environment["CANDOA_UI_TESTING_APPLE_SIGN_IN_WORKING"] == "1"
            : hasStoredToken
    }

    func restoreSessionIfNeeded() async {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        guard accountService.accessToken != nil else {
            isWorking = false
            isSignedIn = false
            hasCloudSession = false
            isLocalOnly = hasCompletedAccountChoice
            return
        }
        await refresh()
    }

    func continueOnThisMac() {
        Task {
            await createAnonymousSession()
        }
    }

    func signInWithApple() {
        Task {
            _ = await authenticateWithApple()
        }
    }

    func refresh() async {
        guard let accessToken = accountService.accessToken else {
            status = nil
            isSignedIn = false
            hasCloudSession = false
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            try await loadSession(accessToken: accessToken)
            if isSignedIn {
                try await refreshAccountStatus(accessToken: accessToken)
            } else {
                status = nil
            }
            errorMessage = nil
        } catch {
            status = nil
            if (error as? CandoaAccountError)?.isAuthenticationFailure == true {
                try? accountService.removeAccessToken()
                isSignedIn = false
                hasCloudSession = false
                isLocalOnly = hasCompletedAccountChoice
            }
            errorMessage = error.localizedDescription
        }
    }

    func startProCheckout() async {
        if !isSignedIn {
            guard await authenticateWithApple() else { return }
        }
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
        let accessToken = accountService.accessToken
        try? accountService.removeAccessToken()
        isSignedIn = false
        hasCloudSession = false
        isLocalOnly = true
        status = nil
        errorMessage = nil
        if let accessToken {
            Task {
                try? await accountService.signOut(accessToken: accessToken)
            }
        }
    }

    private func openBillingURL(_ operation: (String) async throws -> URL) async {
        guard isSignedIn, let accessToken = accountService.accessToken else {
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

    private func authenticateWithApple() async -> Bool {
        guard !isWorking, !appleAuthenticationService.isAuthenticating else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let accessToken = try await appleAuthenticationService.authenticate(
                accessToken: accountService.accessToken
            )
            try accountService.saveAccessToken(accessToken)
            markAccountChoiceCompleted()
            try await loadSession(accessToken: accessToken)
            guard isSignedIn else {
                throw CandoaAccountError.appleSignInFailed
            }
            try await refreshAccountStatus(accessToken: accessToken)
            return true
        } catch {
            if case CandoaAccountError.appleSignInCancelled = error {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func createAnonymousSession() async {
        guard !isWorking else { return }

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1" {
            markAccountChoiceCompleted()
            isSignedIn = false
            isLocalOnly = true
            errorMessage = nil
            return
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let accessToken = try await accountService.signInAnonymously()
            try accountService.saveAccessToken(accessToken)
            try await loadSession(accessToken: accessToken)
            guard hasCloudSession, isLocalOnly, !isSignedIn else {
                throw CandoaAccountError.invalidResponse
            }
            markAccountChoiceCompleted()
        } catch {
            try? accountService.removeAccessToken()
            hasCloudSession = false
            isLocalOnly = false
            isSignedIn = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadSession(accessToken: String) async throws {
        let session = try await accountService.session(accessToken: accessToken)
        hasCloudSession = true
        isLocalOnly = session.user.isAnonymous
        isSignedIn = !session.user.isAnonymous
    }

    private func refreshAccountStatus(accessToken: String) async throws {
        status = try await accountService.accountStatus(accessToken: accessToken)
    }

    private func markAccountChoiceCompleted() {
        UserDefaults.standard.set(true, forKey: Self.accountChoiceKey)
        hasCompletedAccountChoice = true
    }
}
