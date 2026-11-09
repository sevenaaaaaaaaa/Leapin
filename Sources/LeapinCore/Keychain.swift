import Foundation
import Security

/// Thin Keychain wrapper: credentials never live in plain-text config or logs.
public enum Keychain {
    public static let service = "com.leapin.credentials"

    @discardableResult
    public static func set(_ value: String, account: String, service: String = Keychain.service) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func get(account: String, service: String = Keychain.service) -> String? {
        if let value = read(account: account, service: service) { return value }
        // v1.8 rename: read-through credentials saved under the old service,
        // then write them back so the next read is local to Leapin.
        guard service == Keychain.service,
              let legacy = read(account: account, service: "com.touchflow.credentials") else { return nil }
        _ = set(legacy, account: account)
        return legacy
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func delete(account: String, service: String = Keychain.service) -> Bool {
        var removed = delete(account: account, service: service, legacyOnly: false)
        if service == Keychain.service {
            // Also drop the pre-rename copy, otherwise the read-through
            // migration in get() would resurrect a deleted credential.
            removed = delete(account: account, service: "com.touchflow.credentials", legacyOnly: true) || removed
        }
        return removed
    }

    private static func delete(account: String, service: String, legacyOnly: Bool) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}