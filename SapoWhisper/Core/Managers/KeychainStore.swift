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
/// encoded), read once per launch into an in-process cache. Writes always
/// re-create the item (delete + add) so the running build owns it — updating
/// an item owned by another build would re-trigger the consent prompt on
/// every keystroke. Presence hints in UserDefaults (key names only, never
/// secrets) let launch and settings checks answer "is X configured?" without
/// touching the keychain at all, so macOS shows its consent dialog at most
/// once per new build, and only when a secret is actually needed.
///
/// The FILE-BASED keychain is a deliberate choice (re-evaluated 2026-07):
/// `kSecUseDataProtectionKeychain` requires a keychain access group
/// authorized by an embedded provisioning profile, which no build flavor of
/// this app carries — without it every call fails with
/// `errSecMissingEntitlement`, and adding profiles would make app launch
/// depend on profile validity. `kSecAttrAccessibleAfterFirstUnlock` below is
/// inert under the file-based keychain and kept only as forward-compat.
/// Revisit only if iCloud Keychain, Secure Enclave, or biometric gating is
/// ever needed.
enum KeychainStore {
    private static let service = "oli.SapoWhisper"

    /// Single item holding every secret as JSON.
    private static let consolidatedAccount = "api-keys"

    enum Key: String, CaseIterable {
        case aiPolishAPIKey = "ai-polish-api-key"
        case aiPolishOpenRouterAPIKey = "ai-polish-openrouter-api-key"
        case aiPolishLocalServerAPIKey = "ai-polish-local-server-api-key"
        case aiPolishOpenAIAPIKey = "ai-polish-openai-api-key"
        case aiPolishGroqAPIKey = "ai-polish-groq-api-key"
        case aiPolishCustomAPIKey = "ai-polish-custom-api-key"
        case deepgramAPIKey = "deepgram-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"
        case localAIServerAPIKey = "local-ai-server-api-key"
    }

    /// In-process cache: the keychain is hit once per launch, so repeated
    /// reads (settings cards, transcribers) never re-trigger the prompt.
    /// `isReliable` is false when the read was denied — the payload may be
    /// missing keys, so writes must re-read before overwriting.
    private enum CacheState {
        case unloaded
        case loaded(payload: [String: String], isReliable: Bool)
    }

    private static let cache = OSAllocatedUnfairLock<CacheState>(initialState: .unloaded)

    /// cdhash of the running binary; changes on every (ad-hoc) rebuild.
    private static let currentCodeHash: String? = computeCodeHash()

    static func string(for key: Key) -> String? {
        let value = loadPayload()[key.rawValue] ?? ""
        return value.isEmpty ? nil : value
    }

    /// Presence check that avoids the keychain (and its consent prompt): the
    /// loaded cache or the UserDefaults hints answer it. Only pre-hint
    /// installs (owner hash recorded but no hints yet) fall back to one real
    /// read, which then records the hints for every later launch.
    static func hasValue(for key: Key) -> Bool {
        if UIPreviewMode.skipsConsentPrompts {
            return string(for: key) != nil
        }

        let cached: Bool? = cache.withLock { state -> Bool? in
            guard case .loaded(let payload, _) = state else { return nil }
            return !(payload[key.rawValue] ?? "").isEmpty
        }
        if let cached { return cached }

        if let hints = UserDefaults.standard.stringArray(
            forKey: Constants.StorageKeys.keychainStoredKeyHints)
        {
            return hints.contains(key.rawValue)
        }

        guard
            UserDefaults.standard.string(forKey: Constants.StorageKeys.keychainOwnerCodeHash) != nil
        else {
            return false
        }
        return string(for: key) != nil
    }

    /// True while this session's keychain read was denied (the user pressed
    /// "Deny" on the consent dialog): secrets exist but are unreadable until
    /// a retry. UI surfaces use this to offer a recovery path.
    static var isReadDenied: Bool {
        cache.withLock { state in
            if case .loaded(_, false) = state { return true }
            return false
        }
    }

    /// Drops the denied cache and reads again, which lets macOS show the
    /// consent dialog one more time. Returns true when the retry produced a
    /// reliable read.
    @discardableResult
    static func retryDeniedRead() -> Bool {
        cache.withLock { state in
            if case .loaded(_, false) = state {
                state = .unloaded
            }
        }
        _ = loadPayload()
        return cache.withLock { state in
            if case .loaded(_, true) = state { return true }
            return false
        }
    }

    @discardableResult
    static func setString(_ value: String, for key: Key) -> Bool {
        // A denied read this launch means the cache may be missing keys;
        // retry the read before writing so a partial payload can't wipe them.
        cache.withLock { state in
            if case .loaded(_, false) = state {
                state = .unloaded
            }
        }

        var payload = loadPayload()
        // A denied read leaves the payload a stub, and writing it back would
        // delete every other secret the item holds.
        guard !isReadDenied else { return false }

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
        cache.withLock { state in
            if case .loaded(let payload, _) = state { return payload }
            // UI preview and test launches must never hit the keychain:
            // every ad-hoc rebuild would re-trigger the consent dialog.
            if UIPreviewMode.skipsConsentPrompts {
                #if DEBUG
                    if let simulated = simulatedRead.withLock({ $0 }) {
                        state = .loaded(payload: simulated.payload, isReliable: simulated.isReliable)
                        return simulated.payload
                    }
                #endif
                state = .loaded(payload: [:], isReliable: true)
                return [:]
            }
            let (payload, isReliable) = readOrMigratePayload()
            state = .loaded(payload: payload, isReliable: isReliable)
            if isReliable {
                rememberStoredKeyHints(payload)
            }
            return payload
        }
    }

    private static func persist(_ payload: [String: String]) -> Bool {
        if UIPreviewMode.skipsConsentPrompts {
            cache.withLock { $0 = .loaded(payload: payload, isReliable: true) }
            return true
        }
        guard writePayload(payload) else { return false }
        cache.withLock { $0 = .loaded(payload: payload, isReliable: true) }
        rememberOwnership()
        rememberStoredKeyHints(payload)
        return true
    }

    private static func readOrMigratePayload() -> (payload: [String: String], isReliable: Bool) {
        switch readItem(account: consolidatedAccount) {
        case .found(let data):
            let payload = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            adoptOwnershipIfBinaryChanged(payload)
            return (payload, true)
        case .failed(let status):
            // Denied or locked: behave as empty for this launch, but leave
            // hints and ownership untouched so nothing gets overwritten and
            // the next launch can ask again.
            SapoLog.lifecycle.warning(
                "Keychain read failed status=\(status, privacy: .public); secrets unavailable this launch"
            )
            return ([:], false)
        case .missing:
            break
        }

        // First run on this layout: fold the legacy per-key items into the
        // consolidated item, then drop the ones that migrated.
        var migrated: [String: String] = [:]
        for key in Key.allCases {
            if case .found(let data) = readItem(account: key.rawValue),
                let value = String(data: data, encoding: .utf8),
                !value.isEmpty
            {
                migrated[key.rawValue] = value
            }
        }
        guard !migrated.isEmpty else { return ([:], true) }

        if writePayload(migrated) {
            for key in Key.allCases where migrated[key.rawValue] != nil {
                deleteItem(account: key.rawValue)
            }
            rememberOwnership()
            SapoLog.lifecycle.info(
                "Keychain items consolidated count=\(migrated.count, privacy: .public)"
            )
        }
        return (migrated, true)
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

        if writePayload(payload) {
            rememberOwnership()
            SapoLog.lifecycle.info("Keychain item re-owned by current build")
        }
    }

    private static func rememberOwnership() {
        guard let currentCodeHash else { return }
        UserDefaults.standard.set(currentCodeHash, forKey: Constants.StorageKeys.keychainOwnerCodeHash)
    }

    private static func rememberStoredKeyHints(_ payload: [String: String]) {
        let hints = payload.compactMap { $0.value.isEmpty ? nil : $0.key }.sorted()
        UserDefaults.standard.set(hints, forKey: Constants.StorageKeys.keychainStoredKeyHints)
    }

    // MARK: - Raw keychain access

    private enum ReadOutcome {
        case found(Data)
        case missing
        /// Denied or otherwise unreadable — contents unknown.
        case failed(OSStatus)
    }

    private static func writePayload(_ payload: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        // Re-create instead of SecItemUpdate: updating an item owned by
        // another build re-triggers the consent prompt on every write, while
        // delete + add silently hands ownership to this build.
        deleteItem(account: consolidatedAccount)

        var query = baseQuery(account: consolidatedAccount)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func readItem(account: String) -> ReadOutcome {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .missing }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
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

    #if DEBUG
        // MARK: - Test seam

        private struct SimulatedRead: Sendable {
            let payload: [String: String]
            let isReliable: Bool
        }

        private static let simulatedRead = OSAllocatedUnfairLock<SimulatedRead?>(initialState: nil)

        /// Tests never reach the keychain, so a denied read is only reachable
        /// by injecting the outcome here. Pass `nil` to restore the default.
        static func simulateRead(payload: [String: String]?, isReliable: Bool = true) {
            simulatedRead.withLock { state in
                state = payload.map { SimulatedRead(payload: $0, isReliable: isReliable) }
            }
            cache.withLock { $0 = .unloaded }
        }
    #endif
}
