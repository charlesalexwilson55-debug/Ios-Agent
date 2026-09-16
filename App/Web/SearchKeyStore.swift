import Foundation
import Security

/// The user's Tavily search key, kept in the Keychain.
///
/// The user pastes the key in on the Online page; nothing else sets it.
enum SearchKeyStore {
    private static let service = "com.charles.conduit.search"
    private static let account = "tavily"
    private static let fallbackKey = "conduit.search.key"

    static var key: String? {
        var query = baseQuery
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

    static var hasKey: Bool { key != nil }

    /// Saves the key, or removes it when `value` is nil or blank.
    static func save(_ value: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)

        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        var add = baseQuery
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            // A re-signed build can lack a keychain group, which makes every
            // keychain call fail. The key then goes in app preferences, which
            // also stay on this phone.
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
