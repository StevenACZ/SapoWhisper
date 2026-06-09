//
//  EnginePortfolioMigration.swift
//  SapoWhisper
//

import Foundation
import os

/// One-shot migration for the engine portfolio reduction: Apple Speech,
/// Google Cloud STT, and Gemini Audio were removed, so stored selections move
/// to the closest remaining engine and every Google/Gemini credential or
/// preference is purged. Safe to run on every launch — it only acts when a
/// removed value is present.
enum EnginePortfolioMigration {
    static let removedEngineRawValues: Set<String> = ["apple", "google", "gemini_audio"]

    private static let purgedDefaultsKeys = [
        "googleCloudAPIKey",
        "serviceAccountConfigured",
        "geminiAudioModel",
    ]

    static func run(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        migrateSelectedEngineIfNeeded(defaults: defaults)
        purgeRemovedArtifacts(defaults: defaults, fileManager: fileManager)
    }

    /// Pure mapping used by the launch migration and by settings import:
    /// removed engines fall back to a configured cloud engine, else local.
    static func migratedEngine(
        from stored: String,
        hasDeepgramKey: Bool,
        hasElevenLabsKey: Bool
    ) -> String {
        guard removedEngineRawValues.contains(stored) else { return stored }
        if hasDeepgramKey {
            return TranscriptionEngine.deepgram.rawValue
        }
        if hasElevenLabsKey {
            return TranscriptionEngine.elevenLabsScribe.rawValue
        }
        return TranscriptionEngine.whisperLocal.rawValue
    }

    private static func migrateSelectedEngineIfNeeded(defaults: UserDefaults) {
        guard let stored = defaults.string(forKey: Constants.StorageKeys.transcriptionEngine),
            removedEngineRawValues.contains(stored)
        else {
            return
        }

        let migrated = migratedEngine(
            from: stored,
            hasDeepgramKey: !(defaults.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? "").isEmpty,
            hasElevenLabsKey: !(defaults.string(forKey: Constants.StorageKeys.elevenLabsAPIKey) ?? "").isEmpty
        )
        defaults.set(migrated, forKey: Constants.StorageKeys.transcriptionEngine)
        SapoLog.lifecycle.info(
            "Engine migrated from removed value old=\(stored, privacy: .public) new=\(migrated, privacy: .public)"
        )
    }

    private static func purgeRemovedArtifacts(defaults: UserDefaults, fileManager: FileManager) {
        for key in purgedDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            SapoLog.lifecycle.info("Purged removed engine preference key=\(key, privacy: .public)")
        }

        guard
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let credentialsURL =
            appSupport
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("gcloud-credentials.json")
        if fileManager.fileExists(atPath: credentialsURL.path) {
            try? fileManager.removeItem(at: credentialsURL)
            SapoLog.lifecycle.info("Deleted stored Google credentials file")
        }
    }
}
