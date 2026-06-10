//
//  APIKeyKeychainMigration.swift
//  SapoWhisper
//

import Foundation
import os

/// One-shot migration of the engine API keys (Deepgram, ElevenLabs) from
/// UserDefaults plaintext to the Keychain. Safe to run on every launch — it
/// only acts while a legacy value is still present, and it keeps that value
/// when the Keychain write fails so the next launch can retry.
enum APIKeyKeychainMigration {
    private static let migrations: [(defaultsKey: String, keychainKey: KeychainStore.Key)] = [
        (Constants.StorageKeys.deepgramAPIKey, .deepgramAPIKey),
        (Constants.StorageKeys.elevenLabsAPIKey, .elevenLabsAPIKey),
    ]

    static func run(defaults: UserDefaults = .standard) {
        for migration in migrations {
            guard let legacyValue = defaults.string(forKey: migration.defaultsKey) else { continue }

            let trimmed = legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never overwrite a key the user already saved through the Keychain
            // path. Presence check goes through the hints so this launch-time
            // migration cannot trigger the keychain consent dialog.
            if !trimmed.isEmpty, !KeychainStore.hasValue(for: migration.keychainKey) {
                guard KeychainStore.setString(trimmed, for: migration.keychainKey) else {
                    SapoLog.lifecycle.error(
                        "API key Keychain migration failed key=\(migration.keychainKey.rawValue, privacy: .public)"
                    )
                    continue
                }
            }
            defaults.removeObject(forKey: migration.defaultsKey)
            SapoLog.lifecycle.info(
                "API key migrated to Keychain key=\(migration.keychainKey.rawValue, privacy: .public)"
            )
        }
    }
}
