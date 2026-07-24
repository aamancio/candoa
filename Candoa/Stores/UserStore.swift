import AppKit
import AuthenticationServices
import Foundation
import SwiftUI

@MainActor
final class UserStore: ObservableObject {
    @Published private(set) var status: CandoaAccountStatus?
    @Published private(set) var isWorking = false
    @Published private(set) var isStartingSubscription = false
    @Published private(set) var isSigningInWithPasskey = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var subscriptionErrorMessage: String?
    @Published private(set) var accountMessage: String?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var hasCloudSession: Bool
    @Published private(set) var isLocalOnly: Bool
    @Published private(set) var hasCompletedAccountChoice: Bool
    @Published private(set) var hasKnownPasskeyAccount: Bool

    private let accountService: CandoaAccountService
    private let passkeyService: CandoaPasskeyService

    var hasActiveSubscription: Bool { status?.hasActiveSubscription == true }

    static var hasStoredAccountChoice: Bool {
        UserDefaults.standard.bool(forKey: accountChoiceKey)
    }

    private static let accountChoiceKey = "Candoa.HasCompletedAccountChoice"
    private static let knownPasskeyAccountKey = "Candoa.HasKnownPasskeyAccount"

    init(
        accountService: CandoaAccountService = CandoaAccountService(),
        passkeyService: CandoaPasskeyService = CandoaPasskeyService()
    ) {
        self.accountService = accountService
        self.passkeyService = passkeyService
        let hasStoredToken = accountService.accessToken != nil
        isSignedIn = false
        hasCloudSession = hasStoredToken
        isLocalOnly = false
        hasCompletedAccountChoice = hasStoredToken || Self.hasStoredAccountChoice
        let environment = ProcessInfo.processInfo.environment
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

    func signInWithPasskey() {
        Task {
            await restoreWithPasskey()
        }
    }

    func allowCreatingNewPasskeyAccount() {
        hasKnownPasskeyAccount = false
        guard ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] != "1" else { return }
        UserDefaults.standard.removeObject(forKey: Self.knownPasskeyAccountKey)
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

        if accountService.accessToken == nil {
            await createAnonymousSession()
        }
        guard hasCloudSession else {
            subscriptionErrorMessage = errorMessage
                ?? "Candoa couldn’t start checkout. Please try again."
            return
        }
        if status?.hasPasskey != true {
            let registered = await registerPasskey()
            guard registered else { return }
        }
        guard isSignedIn, status?.hasPasskey == true else {
            subscriptionErrorMessage = "Set up your Candoa account before subscribing."
            return
        }
        await openBillingURL(
            failureMessage: "Candoa couldn’t open checkout. Please try again."
        ) { accessToken in
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
        isLocalOnly = false
        hasCompletedAccountChoice = false
        UserDefaults.standard.removeObject(forKey: Self.accountChoiceKey)
        status = nil
        errorMessage = nil
        subscriptionErrorMessage = nil
        accountMessage = nil
        if let accessToken {
            Task {
                try? await accountService.signOut(accessToken: accessToken)
            }
        }
    }

    private func openBillingURL(
        failureMessage: String? = nil,
        _ operation: (String) async throws -> URL
    ) async {
        guard hasCloudSession, let accessToken = accountService.accessToken else {
            errorMessage = "Candoa couldn’t find your account on this Mac."
            subscriptionErrorMessage = failureMessage ?? errorMessage
            return
        }

        isWorking = true
        do {
            let billingURL = try await operation(accessToken)
            isWorking = false
            errorMessage = nil
            subscriptionErrorMessage = nil
            openInDefaultBrowser(billingURL)
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
            subscriptionErrorMessage = failureMessage
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

    private func isPasskeyCancellation(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain
            && error.code == ASAuthorizationError.canceled.rawValue
    }
}
