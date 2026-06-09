//
//  KeychainStore.swift
//  SapoWhisper
//

import Foundation
import Security

/// Minimal Keychain wrapper for API secrets. Items are stored as generic
/// passwords under the app service and stay readable after first unlock so
/// background dictation keeps working across relaunches.
enum KeychainStore {
    private static let service = "oli.SapoWhisper"

    enum Key: String {
        case aiPolishAPIKey = "ai-polish-api-key"
        case deepgramAPIKey = "deepgram-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"
    }

    static func string(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setString(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else { return delete(key) }
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
