import CryptoKit
import Foundation
import Security

/// One passkey held by the built-in authenticator: everything needed to sign
/// for a relying party again, stored as a single keychain item so iCloud
/// Keychain can sync the whole credential between the person's devices.
struct PasskeyCredential: Codable, Equatable, Identifiable {
    /// The credential ID handed to relying parties, base64url.
    let id: String
    let relyingParty: String
    let userHandle: String
    let userName: String
    let userDisplayName: String
    /// P-256 private key, raw representation.
    let privateKey: Data
    let createdAt: Date

    var signingKey: P256.Signing.PrivateKey? {
        try? P256.Signing.PrivateKey(rawRepresentation: privateKey)
    }
}

/// Keychain storage for the built-in authenticator's passkeys (issue #506).
/// Items live in the data-protection keychain like every other Candoa secret
/// (see `KeychainStore`), marked synchronizable so iCloud Keychain roams them
/// end-to-end encrypted — a passkey made on this Mac works on the next one,
/// which is what people expect passkeys to do.
struct PasskeyCredentialStore {
    static let service = "app.candoa.browser.passkeys"

    /// UI-test runs share the real keychain; like the extension records, they
    /// start empty and persist nothing.
    var isPersistenceSuspended = false

    private var transientCredentials: [PasskeyCredential] {
        get { Self.transientStorage }
        nonmutating set { Self.transientStorage = newValue }
    }
    private nonisolated(unsafe) static var transientStorage: [PasskeyCredential] = []

    func all() -> [PasskeyCredential] {
        if isPersistenceSuspended { return transientCredentials }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]) { _, new in new } as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [Data] else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return items
            .compactMap { try? decoder.decode(PasskeyCredential.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func credentials(for relyingParty: String) -> [PasskeyCredential] {
        all().filter { $0.relyingParty == relyingParty }
    }

    func save(_ credential: PasskeyCredential) throws {
        if isPersistenceSuspended {
            transientCredentials.removeAll {
                $0.id == credential.id
                    || ($0.relyingParty == credential.relyingParty && $0.userHandle == credential.userHandle)
            }
            transientCredentials.append(credential)
            return
        }
        // One passkey per account per site: registering again for the same
        // user handle replaces the old key, as platform authenticators do.
        for existing in credentials(for: credential.relyingParty)
        where existing.userHandle == credential.userHandle {
            remove(id: existing.id)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(credential)

        var attributes = baseQuery
        attributes[kSecAttrAccount as String] = credential.id
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var match = baseQuery
            match[kSecAttrAccount as String] = credential.id
            SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func remove(id: String) {
        if isPersistenceSuspended {
            transientCredentials.removeAll { $0.id == id }
            return
        }
        var query = baseQuery
        query[kSecAttrAccount as String] = id
        SecItemDelete(query as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true
        ]
    }
}
