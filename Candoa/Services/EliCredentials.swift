import Foundation
import Security

enum EliPreferences {
    static let defaultDirectModelID = "openai/gpt-5.6-luna"

    static var connection: EliConnection {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.askConnection)
        let connection = stored.flatMap(EliConnection.init(rawValue:)) ?? .candoaCloud
#if DEBUG
        return connection
#else
        // The environment credential source exists only for development.
        return connection == .environment ? .candoaCloud : connection
#endif
    }

    static func setConnection(_ connection: EliConnection) {
        UserDefaults.standard.set(
            connection.rawValue,
            forKey: SettingsOption.askConnection
        )
    }

    /// Provider-qualified hosted selection; empty means the account's
    /// server-side default model.
    static var hostedModelID: String? {
        let stored = UserDefaults.standard.string(forKey: SettingsOption.askHostedModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Provider-qualified BYOK selection, coerced back into the curated
    /// catalog when the stored value is stale.
    static var directModel: AIModel {
        if let stored = UserDefaults.standard.string(forKey: SettingsOption.askDirectModel),
           let model = AIModelCatalog.model(forID: stored) {
            return model
        }
        return AIModelCatalog.model(forID: defaultDirectModelID)
            ?? AIModelCatalog.directModels[0]
    }

    static var reasoningEffort: AIReasoningEffort {
        UserDefaults.standard.string(forKey: SettingsOption.askReasoningEffort)
            .flatMap(AIReasoningEffort.init(rawValue:)) ?? .low
    }

    static func environmentAPIKey(for provider: AIProvider) -> String? {
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
            return EliKeychain.apiKey(for: directModel.provider)
        case .environment:
            return environmentAPIKey(for: directModel.provider)
        }
    }

    static var hasDirectEliAccess: Bool {
        connection != .candoaCloud && directAPIKey != nil
    }
}

enum EliKeychain {
    private static func store(for provider: AIProvider) -> KeychainStore {
        KeychainStore(
            service: "app.candoa.browser.Ask",
            account: provider.keychainAccount
        )
    }

    static func apiKey(for provider: AIProvider) -> String? {
        store(for: provider).read()
    }

    static func hasAPIKey(for provider: AIProvider) -> Bool {
        apiKey(for: provider) != nil
    }

    static func save(_ apiKey: String, for provider: AIProvider) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw EliKeychainError.emptyKey(provider) }

        let status = store(for: provider).save(trimmedKey)
        guard status == errSecSuccess else { throw EliKeychainError.unavailable(status) }
    }

    static func remove(for provider: AIProvider) throws {
        let status = store(for: provider).remove()
        guard status == errSecSuccess else { throw EliKeychainError.unavailable(status) }
    }
}

private enum EliKeychainError: LocalizedError {
    case emptyKey(AIProvider)
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
