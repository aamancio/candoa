import Foundation
import Security

enum CandoaEliPreferences {
    static let defaultModel = "gpt-5.6-luna"

    static var model: String {
        let storedModel = UserDefaults.standard.string(forKey: CandoaSettingsOption.askModel) ?? ""
        let trimmedModel = storedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? defaultModel : trimmedModel
    }

    static var usesPersonalOpenAIKey: Bool {
        UserDefaults.standard.bool(forKey: CandoaSettingsOption.askUsesPersonalOpenAIKey)
    }
}

enum CandoaEliKeychain {
    private static let store = CandoaKeychainStore(
        service: "app.candoa.browser.Ask",
        account: "openai-api-key"
    )

    static var apiKey: String? {
        store.read()
    }

    static var hasAPIKey: Bool {
        apiKey != nil
    }

    static func save(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw CandoaEliKeychainError.emptyKey }

        let status = store.save(trimmedKey)
        guard status == errSecSuccess else { throw CandoaEliKeychainError.unavailable(status) }
    }

    static func remove() throws {
        let status = store.remove()
        guard status == errSecSuccess else { throw CandoaEliKeychainError.unavailable(status) }
    }
}

private enum CandoaEliKeychainError: LocalizedError {
    case emptyKey
    case unavailable(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter an OpenAI API key before saving."
        case .unavailable:
            return "Candoa could not save the API key in Keychain."
        }
    }
}

