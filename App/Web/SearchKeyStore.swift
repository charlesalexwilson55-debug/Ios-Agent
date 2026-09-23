import Foundation
import Security

/// The user's Exa and Tavily search keys, kept separately in the Keychain.
///
/// `key`, `hasKey` and `save(_:)` remain the Tavily API for existing callers.
enum SearchKeyStore {
    private static let service = "com.charles.conduit.search"
    private static let tavilyAccount = "tavily"
    private static let exaAccount = "exa"
    private static let tavilyFallbackKey = "conduit.search.key"
    private static let exaFallbackKey = "conduit.search.exa.key"

    static var key: String? {
        read(account: tavilyAccount, fallbackKey: tavilyFallbackKey)
    }

    static var tavilyKey: String? { key }
    static var exaKey: String? { read(account: exaAccount, fallbackKey: exaFallbackKey) }

    static var hasKey: Bool { key != nil }
    static var hasTavilyKey: Bool { key != nil }
    static var hasExaKey: Bool { exaKey != nil }
    static var hasResearchKey: Bool { hasExaKey || hasTavilyKey }

    /// Backward-compatible Tavily save API.
    static func save(_ value: String?) {
        save(value, account: tavilyAccount, fallbackKey: tavilyFallbackKey)
    }

    static func saveTavily(_ value: String?) {
        save(value)
    }

    static func saveExa(_ value: String?) {
        save(value, account: exaAccount, fallbackKey: exaFallbackKey)
    }

    private static func read(account: String, fallbackKey: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let stored = UserDefaults.standard.string(forKey: fallbackKey)
        return stored?.isEmpty == false ? stored : nil
    }

    /// Saves one provider key, or removes it when `value` is nil or blank.
    private static func save(_ value: String?, account: String, fallbackKey: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)

        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // A re-signed build can lack a keychain group, which makes every
            // keychain call fail. The key then goes in app preferences, which
            // also stay on this phone.
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
