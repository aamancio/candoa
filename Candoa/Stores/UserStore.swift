import AppKit
import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var isStartingSubscription = false
    @Published private(set) var isAwaitingSubscriptionActivation = false
    @Published private(set) var isReconcilingSubscription = false
    @Published private(set) var isSigningInWithApple = false
    @Published private(set) var isSigningInWithPasskey = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var subscriptionErrorMessage: String?
    @Published private(set) var accountMessage: String?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var hasCloudSession: Bool
    @Published private(set) var isLocalOnly: Bool
    @Published private(set) var hasCompletedAccountChoice: Bool
    @Published private(set) var hasKnownPasskeyAccount: Bool
    @Published private(set) var signOutGeneration = 0

    private let accountService: CandoaAccountService
    private let appleSignInService: CandoaAppleSignInService
    private let passkeyService: CandoaPasskeyService
    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }
    var canCreateReplacementPasskeyAccount: Bool {
        guard !isSignedIn,
              hasKnownPasskeyAccount,
              let errorMessage = errorMessage?.lowercased() else {
            return false
        }
        return errorMessage.contains("passkey") && errorMessage.contains("not found")
    }

    static var hasStoredAccountChoice: Bool {
        UserDefaults.standard.bool(forKey: accountChoiceKey)
    }

    private static let accountChoiceKey = "Candoa.HasCompletedAccountChoice"
    private static let knownPasskeyAccountKey =
        "Candoa.HasKnownPasskeyAccount.www.candoa.app"

    init(
        accountService: CandoaAccountService = CandoaAccountService(),
        appleSignInService: CandoaAppleSignInService = CandoaAppleSignInService(),
        passkeyService: CandoaPasskeyService = CandoaPasskeyService()
    ) {
        self.accountService = accountService
        self.appleSignInService = appleSignInService
        self.passkeyService = passkeyService
        let hasStoredToken = accountService.accessToken != nil
        isSignedIn = false
        hasCloudSession = hasStoredToken
        isLocalOnly = false
        let environment = ProcessInfo.processInfo.environment
        hasCompletedAccountChoice = environment["CANDOA_UI_TESTING"] == "1"
            ? false
            : hasStoredToken || Self.hasStoredAccountChoice
        hasKnownPasskeyAccount = environment["CANDOA_UI_TESTING"] == "1"
            ? environment["CANDOA_UI_TESTING_KNOWN_PASSKEY_ACCOUNT"] == "1"
            : UserDefaults.standard.bool(forKey: Self.knownPasskeyAccountKey)
        isWorking = environment["CANDOA_UI_TESTING"] == "1" ? false : hasStoredToken
    }

    func restoreSessionIfNeeded() async {
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        guard accountService.accessToken != nil else {
            isWorking = false
            isSignedIn = false
            hasCloudSession = false
            isLocalOnly = hasCompletedAccountChoice
            if hasCompletedAccountChoice {
                await createAnonymousSession()
            }
            return
        }
        await refresh()
    }

    func continueOnThisMac() {
        Task {
            await createAnonymousSession()
        }
    }

    func createPasskey() {
        Task {
            await registerPasskey()
        }
    }

    func signInWithApple() {
        Task {
            await authenticateWithApple()
        }
    }

    func signInWithPasskey() {
        Task {
            await restoreWithPasskey()
        }
    }

    func allowCreatingNewPasskeyAccount() {
        hasKnownPasskeyAccount = false
        errorMessage = nil
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        UserDefaults.standard.removeObject(forKey: Self.knownPasskeyAccountKey)
    }

    func createReplacementPasskeyAccount() {
        try? accountService.removeAccessToken()
        status = nil
        isSignedIn = false
        hasCloudSession = false
        isLocalOnly = false
        isAwaitingSubscriptionActivation = false
        isReconcilingSubscription = false
        allowCreatingNewPasskeyAccount()
        createPasskey()
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
            try await refreshAccountStatus(accessToken: accessToken)
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
        guard !isStartingSubscription else { return }

        isStartingSubscription = true
        defer { isStartingSubscription = false }
        subscriptionErrorMessage = nil

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_CHECKOUT_FAILURE"] == "1" {
            isWorking = true
            await Task.yield()
            isWorking = false
            subscriptionErrorMessage = "Candoa checkout is temporarily unavailable."
            return
        }
        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_CHECKOUT_SUCCESS"] == "1" {
            isAwaitingSubscriptionActivation = true
            isReconcilingSubscription = true
            await Task.yield()
            try? await Task.sleep(for: .seconds(2))
            status = CandoaAccountStatus(
                hasPasskey: true,
                hasAppleAccount: true,
                planID: "pro",
                allowedModelIDs: ["openai/gpt-5"]
            )
            isSignedIn = true
            hasCloudSession = true
            isLocalOnly = false
            isAwaitingSubscriptionActivation = false
            isReconcilingSubscription = false
            accountMessage = "Your Candoa subscription is active."
            return
        }

        if status?.hasAppleAccount != true {
            await authenticateWithApple()
        }
        guard isSignedIn, status?.hasAppleAccount == true else {
            subscriptionErrorMessage = errorMessage
                ?? "Sign in with Apple before subscribing."
            return
        }

        await refresh()
        guard isSignedIn, status?.hasAppleAccount == true else {
            subscriptionErrorMessage = errorMessage
                ?? "Candoa couldn’t verify your account before checkout."
            return
        }
        if hasActiveSubscription {
            isAwaitingSubscriptionActivation = false
            accountMessage = "Your Candoa subscription is active."
            return
        }

        let didOpenCheckout = await openBillingURL(
            failureMessage: "Candoa couldn’t open checkout. Please try again."
        ) { accessToken in
            try await accountService.proCheckoutURL(accessToken: accessToken)
        }
        if didOpenCheckout {
            isAwaitingSubscriptionActivation = true
            return
        }

        // The server may have accepted Stripe's webhook after the preflight
        // refresh but before this Checkout request. Reconcile once so a stale
        // Subscribe action becomes the active plan instead of an error.
        await refresh()
        if hasActiveSubscription {
            isAwaitingSubscriptionActivation = false
            subscriptionErrorMessage = nil
            accountMessage = "Your Candoa subscription is active."
        }
    }

    func openBillingPortal() async {
        _ = await openBillingURL { accessToken in
            try await accountService.billingPortalURL(accessToken: accessToken)
        }
    }

    func reconcilePendingSubscriptionIfNeeded(for url: URL? = nil) async {
        guard isAwaitingSubscriptionActivation, !isReconcilingSubscription else { return }
        if let url, !Self.isBillingSuccessURL(url) {
            return
        }

        isReconcilingSubscription = true
        defer { isReconcilingSubscription = false }
        subscriptionErrorMessage = nil

        // Stripe redirects before its signed webhook is guaranteed to have
        // reached Cloud. Retry only for this pending checkout and then stop.
        for delay in [0, 1, 2, 4, 8, 15] {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                } catch {
                    return
                }
            }

            await refresh()
            if hasActiveSubscription {
                isAwaitingSubscriptionActivation = false
                subscriptionErrorMessage = nil
                accountMessage = "Your Candoa subscription is active."
                return
            }
        }

        subscriptionErrorMessage =
            "Candoa is still confirming your subscription. Try again in a moment."
    }

    func signOut() {
        let accessToken = accountService.accessToken
        try? accountService.removeAccessToken()
        isSignedIn = false
        hasCloudSession = false
        isLocalOnly = false
        hasCompletedAccountChoice = false
        isAwaitingSubscriptionActivation = false
        isReconcilingSubscription = false
        UserDefaults.standard.removeObject(forKey: Self.accountChoiceKey)
        status = nil
        errorMessage = nil
        subscriptionErrorMessage = nil
        accountMessage = nil
        signOutGeneration &+= 1
        if let accessToken {
            Task {
                try? await accountService.signOut(accessToken: accessToken)
            }
        }
    }

    private func openBillingURL(
        failureMessage: String? = nil,
        _ operation: (String) async throws -> URL
    ) async -> Bool {
        guard hasCloudSession, let accessToken = accountService.accessToken else {
            errorMessage = "Candoa couldn’t find your account on this Mac."
            subscriptionErrorMessage = failureMessage ?? errorMessage
            return false
        }

        isWorking = true
        do {
            let billingURL = try await operation(accessToken)
            isWorking = false
            errorMessage = nil
            subscriptionErrorMessage = nil
            openInDefaultBrowser(billingURL)
            return true
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
            subscriptionErrorMessage = failureMessage
            return false
        }
    }

    private func openInDefaultBrowser(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration)
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
            if let accessToken = accountService.accessToken {
                try await loadSession(accessToken: accessToken)
                guard hasCloudSession, isLocalOnly else {
                    throw CandoaAccountError.invalidResponse
                }
                markAccountChoiceCompleted()
                return
            }
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

    private func authenticateWithApple() async {
        guard !isSigningInWithApple, !isWorking else { return }

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_APPLE_SUCCESS"] == "1" {
            isSignedIn = true
            isLocalOnly = false
            hasCloudSession = true
            status = CandoaAccountStatus(
                hasPasskey: false,
                hasAppleAccount: true,
                planID: status?.planID ?? "free",
                allowedModelIDs: status?.allowedModelIDs ?? []
            )
            markAccountChoiceCompleted()
            errorMessage = nil
            accountMessage = "You’re signed in with Apple."
            return
        }

        isSigningInWithApple = true
        isWorking = true
        errorMessage = nil
        accountMessage = nil
        let previousAccessToken = accountService.accessToken
        defer {
            isSigningInWithApple = false
            isWorking = false
        }

        do {
            let shouldLinkExistingAccount =
                isSignedIn && !isLocalOnly && previousAccessToken != nil
            let authorizationURL = try await accountService.appleSignInURL(
                accessToken: shouldLinkExistingAccount ? previousAccessToken : nil
            )
            let code = try await appleSignInService.authenticate(at: authorizationURL)
            let accessToken = try await accountService.exchangeAppleSignInCode(code)

            if let previousAccessToken, previousAccessToken != accessToken {
                try? await accountService.signOut(accessToken: previousAccessToken)
            }
            try accountService.saveAccessToken(accessToken)
            try await loadSession(accessToken: accessToken)
            try await refreshAccountStatus(accessToken: accessToken)
            guard isSignedIn, status?.hasAppleAccount == true else {
                throw CandoaAccountError.invalidResponse
            }

            markAccountChoiceCompleted()
            errorMessage = nil
            accountMessage = hasActiveSubscription
                ? "Your Candoa subscription has been restored."
                : "You’re signed in with Apple."
        } catch {
            if Self.isAppleSignInCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func registerPasskey() async -> Bool {
        guard !isWorking else { return false }

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PASSKEY_SUCCESS"] == "1" {
            isSignedIn = true
            isLocalOnly = false
            hasCloudSession = true
            markAccountChoiceCompleted()
            return true
        }

        isWorking = true
        errorMessage = nil
        accountMessage = nil
        var createdTemporarySession = false
        defer { isWorking = false }

        do {
            if accountService.accessToken == nil {
                let accessToken = try await accountService.signInAnonymously()
                try accountService.saveAccessToken(accessToken)
                try await loadSession(accessToken: accessToken)
                createdTemporarySession = true
            }

            guard let accessToken = accountService.accessToken,
                  hasCloudSession else {
                throw CandoaAccountError.invalidResponse
            }
            if status?.hasPasskey == true {
                markAccountChoiceCompleted()
                return true
            }

            let ceremony = try await accountService.passkeyRegistrationOptions(
                accessToken: accessToken
            )
            let credential = try await passkeyService.createPasskey(options: ceremony.options)
            try await accountService.verifyPasskeyRegistration(
                credential,
                accessToken: accessToken,
                challengeCookie: ceremony.challengeCookie
            )
            try await loadSession(accessToken: accessToken)
            guard isSignedIn, !isLocalOnly else {
                throw CandoaAccountError.invalidResponse
            }
            try await refreshAccountStatus(accessToken: accessToken)
            guard status?.hasPasskey == true else {
                throw CandoaAccountError.invalidResponse
            }
            markAccountChoiceCompleted()
            accountMessage = "Your Candoa account is ready."
            return true
        } catch {
            if createdTemporarySession {
                if let accessToken = accountService.accessToken {
                    try? await accountService.signOut(accessToken: accessToken)
                }
                try? accountService.removeAccessToken()
                hasCloudSession = false
                isLocalOnly = false
                isSignedIn = false
            }
            if isPasskeyCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func restoreWithPasskey() async {
        guard !isSigningInWithPasskey, !isWorking else { return }

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PASSKEY_NOT_FOUND"] == "1" {
            errorMessage = "Passkey not found"
            return
        }

        if ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PASSKEY_SUCCESS"] == "1" {
            isSignedIn = true
            isLocalOnly = false
            hasCloudSession = true
            markAccountChoiceCompleted()
            return
        }

        isSigningInWithPasskey = true
        isWorking = true
        errorMessage = nil
        accountMessage = nil
        defer {
            isSigningInWithPasskey = false
            isWorking = false
        }

        do {
            let ceremony = try await accountService.passkeyAuthenticationOptions()
            let credential = try await passkeyService.signIn(options: ceremony.options)
            let accessToken = try await accountService.verifyPasskeyAuthentication(
                credential,
                challengeCookie: ceremony.challengeCookie
            )
            try accountService.saveAccessToken(accessToken)
            try await loadSession(accessToken: accessToken)
            guard isSignedIn, !isLocalOnly else {
                throw CandoaAccountError.invalidResponse
            }
            try await refreshAccountStatus(accessToken: accessToken)
            markAccountChoiceCompleted()
            accountMessage = hasActiveSubscription
                ? "Your Candoa subscription has been restored."
                : "You’re signed in to Candoa."
        } catch {
            if isPasskeyCancellation(error) {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
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
        if status?.hasPasskey == true {
            markPasskeyAccountKnown()
        }
    }

    private func markAccountChoiceCompleted() {
        UserDefaults.standard.set(true, forKey: Self.accountChoiceKey)
        hasCompletedAccountChoice = true
    }

    private func markPasskeyAccountKnown() {
        hasKnownPasskeyAccount = true
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        UserDefaults.standard.set(true, forKey: Self.knownPasskeyAccountKey)
    }

    private static func isBillingSuccessURL(_ url: URL) -> Bool {
        guard url.path == "/billing/success" else { return false }
        switch url.host(percentEncoded: false)?.lowercased() {
        case "candoa.app", "www.candoa.app", "localhost", "127.0.0.1":
            return true
        default:
            return false
        }
    }

    private func isPasskeyCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain
            && error.code == ASAuthorizationError.canceled.rawValue
    }

    private static func isAppleSignInCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == ASWebAuthenticationSessionError.errorDomain
            && error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }
}
