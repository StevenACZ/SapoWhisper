//
//  KeychainStore.swift
//  SapoWhisper
//

import Foundation
import Security
import os

/// Minimal Keychain wrapper for API secrets.
///
/// Every secret lives inside one consolidated generic-password item (JSON
/// encoded), read once per launch into an in-process cache. Combined with
/// re-owning the item when the binary changes, macOS shows its keychain
/// consent dialog at most once per new build instead of once per key and
/// launch.
enum KeychainStore {
    private static let service = "oli.SapoWhisper"

    /// Single item holding every secret as JSON.
    private static let consolidatedAccount = "api-keys"

    enum Key: String, CaseIterable {
        case aiPolishAPIKey = "ai-polish-api-key"
        case deepgramAPIKey = "deepgram-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"
    }

    /// In-process cache: the keychain is hit once per launch, so repeated
    /// reads (settings cards, transcribers) never re-trigger the prompt.
    private static let cachedPayload = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

    /// cdhash of the running binary; changes on every (ad-hoc) rebuild.
    private static let currentCodeHash: String? = computeCodeHash()

    static func string(for key: Key) -> String? {
        let value = loadPayload()[key.rawValue] ?? ""
        return value.isEmpty ? nil : value
    }

    @discardableResult
    static func setString(_ value: String, for key: Key) -> Bool {
        var payload = loadPayload()
        if value.isEmpty {
            payload.removeValue(forKey: key.rawValue)
        } else {
            payload[key.rawValue] = value
        }
        return persist(payload)
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        setString("", for: key)
    }

    // MARK: - Consolidated payload

    private static func loadPayload() -> [String: String] {
        cachedPayload.withLock { cached in
            if let cached { return cached }
            // UI preview and test launches must never hit the keychain:
            // every ad-hoc rebuild would re-trigger the consent dialog.
            let payload = UIPreviewMode.skipsConsentPrompts ? [:] : readOrMigratePayload()
            cached = payload
            return payload
        }
    }

    private static func persist(_ payload: [String: String]) -> Bool {
        if UIPreviewMode.skipsConsentPrompts {
            cachedPayload.withLock { $0 = payload }
            return true
        }
        guard writePayload(payload) else { return false }
        cachedPayload.withLock { $0 = payload }
        rememberOwnership()
        return true
    }

    private static func readOrMigratePayload() -> [String: String] {
        if let data = itemData(account: consolidatedAccount) {
            let payload = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            adoptOwnershipIfBinaryChanged(payload)
            return payload
        }

        // First run on this layout: fold the legacy per-key items into the
        // consolidated item, then drop the ones that migrated.
        var migrated: [String: String] = [:]
        for key in Key.allCases {
            if let data = itemData(account: key.rawValue),
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            {
                migrated[key.rawValue] = value
            }
        }
        guard !migrated.isEmpty else { return [:] }

        if writePayload(migrated) {
            for key in Key.allCases where migrated[key.rawValue] != nil {
                deleteItem(account: key.rawValue)
            }
            rememberOwnership()
            SapoLog.lifecycle.info(
                "Keychain items consolidated count=\(migrated.count, privacy: .public)"
            )
        }
        return migrated
    }

    /// Ad-hoc rebuilds change the code signature, so the item's ACL no longer
    /// trusts the app and macOS prompts again. After the user allows the read
    /// once, re-create the item so the running build owns it and later
    /// launches stay silent.
    private static func adoptOwnershipIfBinaryChanged(_ payload: [String: String]) {
        guard !payload.isEmpty, let currentCodeHash else { return }
        guard
            UserDefaults.standard.string(forKey: Constants.StorageKeys.keychainOwnerCodeHash)
                != currentCodeHash
        else { return }

        deleteItem(account: consolidatedAccount)
        if writePayload(payload) {
            rememberOwnership()
            SapoLog.lifecycle.info("Keychain item re-owned by current build")
        }
    }

    private static func rememberOwnership() {
        guard let currentCodeHash else { return }
        UserDefaults.standard.set(currentCodeHash, forKey: Constants.StorageKeys.keychainOwnerCodeHash)
    }

    // MARK: - Raw keychain access

    private static func writePayload(_ payload: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let updateStatus = SecItemUpdate(
            baseQuery(account: consolidatedAccount) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = baseQuery(account: consolidatedAccount)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func itemData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private static func deleteItem(account: String) {
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func computeCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let cdhash = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }

        return cdhash.map { String(format: "%02x", $0) }.joined()
    }
}
