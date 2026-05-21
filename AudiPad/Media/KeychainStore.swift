import Foundation
import Security

/// Tiny Keychain wrapper for OAuth refresh tokens. UserDefaults is the
/// wrong place for these — they're long-lived bearer credentials that
/// can fetch a fresh access token in perpetuity. Keychain gives us
/// real OS-level encryption + the right `Accessible` semantics so the
/// refresh works the moment the device is unlocked once after a
/// reboot (`AfterFirstUnlock`) — important for the car install where
/// the iPad may reboot overnight and the user wants AudiPad live the
/// instant ignition powers it back up.
enum KeychainStore {
    /// Service identifier shared across all AudiPad Keychain items.
    /// Tied to the bundle identifier so multiple installs don't see
    /// each other's tokens.
    private static let service = "net.absum.audipad"

    static func setString(_ value: String?, forKey key: String) {
        guard let value, let data = value.data(using: .utf8) else {
            delete(key: key)
            return
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            query.merge(attrs) { _, new in new }
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func getString(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
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
