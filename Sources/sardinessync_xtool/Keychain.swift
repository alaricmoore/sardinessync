//
//  Keychain.swift
//  healthsync
//
//  Minimal Keychain wrapper for secrets that shouldn't live in UserDefaults.
//  Used for the UV wearable bearer token; the existing HealthKit token still
//  lives in @AppStorage and is intentionally NOT migrated here (out of scope
//  for the BLE work; migrating it would require touching every binding site).
//

import Foundation
import Security

enum Keychain {
    private static let service = "com.biotracking.healthsync.wearable"

    static let wearableTokenKey = "wearable_bearer_token"

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        let data = Data(value.utf8)
        // SecItemAdd fails with errSecDuplicateItem if the key exists, so we
        // delete-then-add. Cleaner than branching on SecItemUpdate paths.
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
