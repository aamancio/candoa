import Foundation
import Security

enum CandoaEliPreferences {
    static let defaultDirectModelID = "openai/gpt-5.6-luna"

    static var connection: CandoaEliConnection {
        let stored = UserDefaults.standard.string(forKey: CandoaSettingsOption.askConnection)
        let connection = stored.flatMap(CandoaEliConnection.init(rawValue:)) ?? .candoaCloud
#if DEBUG
        return connection
#else
        // The environment credential source exists only for development.
        return connection == .environment ? .candoaCloud : connection
#endif
    }

    static func setConnection(_ connection: CandoaEliConnection) {
        UserDefaults.standard.set(
            connection.rawValue,
            forKey: CandoaSettingsOption.askConnection
        )
    }

    /// Provider-qualified hosted selection; empty means the account's
    /// server-side default model.
    static var hostedModelID: String? {
        let stored = UserDefaults.standard.string(forKey: CandoaSettingsOption.askHostedModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Provider-qualified BYOK selection, coerced back into the curated
    /// catalog when the stored value is stale.
    static var directModel: CandoaAIModel {
        if let stored = UserDefaults.standard.string(forKey: CandoaSettingsOption.askDirectModel),
           let model = CandoaAIModelCatalog.model(forID: stored) {
            return model
        }
        return CandoaAIModelCatalog.model(forID: defaultDirectModelID)
            ?? CandoaAIModelCatalog.directModels[0]
    }

    static var reasoningEffort: CandoaAIReasoningEffort {
        UserDefaults.standard.string(forKey: CandoaSettingsOption.askReasoningEffort)
            .flatMap(CandoaAIReasoningEffort.init(rawValue:)) ?? .low
    }

    static func environmentAPIKey(for provider: CandoaAIProvider) -> String? {
#if DEBUG
        let value = ProcessInfo.processInfo.environment[provider.environmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
#else
        return nil
#endif
    }

    /// The API key for the selected direct connection, or nil when the route
    /// is not usable (no saved key, or no development environment key).
    static var directAPIKey: String? {
        switch connection {
        case .candoaCloud:
            return nil
        case .personalKey:
            return CandoaEliKeychain.apiKey(for: directModel.provider)
        case .environment:
            return environmentAPIKey(for: directModel.provider)
        }
    }

    static var hasDirectEliAccess: Bool {
        connection != .candoaCloud && directAPIKey != nil
    }
}

enum CandoaEliKeychain {
    private static func store(for provider: CandoaAIProvider) -> CandoaKeychainStore {
        CandoaKeychainStore(
            service: "app.candoa.browser.Ask",
            account: provider.keychainAccount
        )
    }

    static func apiKey(for provider: CandoaAIProvider) -> String? {
        store(for: provider).read()
    }

    static func hasAPIKey(for provider: CandoaAIProvider) -> Bool {
        apiKey(for: provider) != nil
    }

    static func save(_ apiKey: String, for provider: CandoaAIProvider) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw CandoaEliKeychainError.emptyKey(provider) }

        let status = store(for: provider).save(trimmedKey)
        guard status == errSecSuccess else { throw CandoaEliKeychainError.unavailable(status) }
    }

    static func remove(for provider: CandoaAIProvider) throws {
        let status = store(for: provider).remove()
        guard status == errSecSuccess else { throw CandoaEliKeychainError.unavailable(status) }
    }
}

private enum CandoaEliKeychainError: LocalizedError {
    case emptyKey(CandoaAIProvider)
    case unavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey(let provider):
            return "Enter \(provider.displayName == "OpenAI" ? "an" : "a") \(provider.displayName) API key before saving."
        case .unavailable:
            return "Candoa could not save the API key in Keychain."
        }
    }
}
