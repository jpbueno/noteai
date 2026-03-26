import Foundation
import Security

/// Simple Keychain wrapper for storing auth tokens securely.
enum KeychainHelper {
    private static let service = "com.noteai.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Centralized storage for LLM API keys.
/// Uses Keychain for secure-at-rest storage and supports one-time migration from legacy UserDefaults keys.
enum APIKeyStore {
    private static let genericLegacyKey = "llmAPIKey"

    static func key(for provider: LLMProviderType) -> String {
        if let providerKey = KeychainHelper.load(key: keychainKey(for: provider)), !providerKey.isEmpty {
            return providerKey
        }
        if let genericKey = KeychainHelper.load(key: genericLegacyKey), !genericKey.isEmpty {
            return genericKey
        }
        return ProcessInfo.processInfo.environment[provider.envKeyName] ?? ""
    }

    static func save(_ value: String, for provider: LLMProviderType) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keychainKey(for: provider)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: key)
        } else {
            KeychainHelper.save(key: key, value: trimmed)
        }
        // Clear legacy plain-text storage once migrated.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey(for: provider))
    }

    static func load(for provider: LLMProviderType) -> String {
        KeychainHelper.load(key: keychainKey(for: provider)) ?? ""
    }

    static func migrateLegacyKeysFromUserDefaults() {
        for provider in LLMProviderType.allCases {
            let defaultsKey = legacyDefaultsKey(for: provider)
            let legacy = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            let existing = KeychainHelper.load(key: keychainKey(for: provider)) ?? ""
            if !legacy.isEmpty && existing.isEmpty {
                KeychainHelper.save(key: keychainKey(for: provider), value: legacy)
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let genericLegacy = UserDefaults.standard.string(forKey: genericLegacyKey) ?? ""
        let genericExisting = KeychainHelper.load(key: genericLegacyKey) ?? ""
        if !genericLegacy.isEmpty && genericExisting.isEmpty {
            KeychainHelper.save(key: genericLegacyKey, value: genericLegacy)
            UserDefaults.standard.removeObject(forKey: genericLegacyKey)
        }
    }

    private static func keychainKey(for provider: LLMProviderType) -> String {
        "apiKey_\(provider.rawValue)"
    }

    private static func legacyDefaultsKey(for provider: LLMProviderType) -> String {
        "apiKey_\(provider.rawValue)"
    }
}
