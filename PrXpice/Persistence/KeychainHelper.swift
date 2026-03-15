import Foundation
import Security

/// Simple Keychain wrapper for storing passwords and API token secrets.
///
/// On macOS Catalyst, SecItemAdd requires a keychain-access-groups entitlement
/// which debug builds lack. As a workaround, macOS uses UserDefaults with a
/// private prefix. iOS always uses the Keychain.
enum KeychainHelper {
    private static let service = "com.prxpice"
    private static let udPrefix = "com.prxpice.secret."

    // MARK: - Public API

    @discardableResult
    static func save(key: String, string: String) -> Bool {
#if targetEnvironment(macCatalyst)
        UserDefaults.standard.set(string, forKey: udPrefix + key)
        return true
#else
        guard let data = string.data(using: .utf8) else { return false }
        return saveKeychain(key: key, data: data)
#endif
    }

    static func loadString(key: String) -> String? {
#if targetEnvironment(macCatalyst)
        return UserDefaults.standard.string(forKey: udPrefix + key)
#else
        guard let data = loadKeychain(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
#endif
    }

    @discardableResult
    static func delete(key: String) -> Bool {
#if targetEnvironment(macCatalyst)
        UserDefaults.standard.removeObject(forKey: udPrefix + key)
        return true
#else
        return deleteKeychain(key: key)
#endif
    }

    // MARK: - iOS Keychain (not used on macCatalyst)

#if !targetEnvironment(macCatalyst)
    private static func saveKeychain(key: String, data: Data) -> Bool {
        deleteKeychain(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func loadKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func deleteKeychain(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
#endif
}
