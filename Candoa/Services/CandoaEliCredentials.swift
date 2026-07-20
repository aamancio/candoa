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
    private static let service = "app.candoa.browser.Ask"
    private static let account = "openai-api-key"

    static var apiKey: String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            baseQuery.merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]) { _, new in new } as CFDictionary,
            &result
        )

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static var hasAPIKey: Bool {
        apiKey != nil
    }

    static func save(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw CandoaEliKeychainError.emptyKey }

        let keyData = Data(trimmedKey.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: keyData] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(
                baseQuery.merging([
                    kSecValueData as String: keyData,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
                ]) { _, new in new } as CFDictionary,
                nil
            )
            guard addStatus == errSecSuccess else { throw CandoaEliKeychainError.unavailable(addStatus) }
            return
        }

        guard updateStatus == errSecSuccess else { throw CandoaEliKeychainError.unavailable(updateStatus) }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CandoaEliKeychainError.unavailable(status)
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

