//
//  EnginePortfolioMigration.swift
//  SapoWhisper
//

import Foundation
import os

/// One-shot migration for the engine portfolio reduction: Apple Speech,
/// Google Cloud STT, Gemini Audio, and WhisperKit were removed, so stored
/// selections move to the closest remaining engine and every removed-engine
/// credential, preference, or on-disk model is purged. Safe to run on every
/// launch — it only acts when a removed value is present.
enum EnginePortfolioMigration {
    static let removedEngineRawValues: Set<String> = ["apple", "google", "gemini_audio", "whisper"]

    /// WhisperKit's raw value; it maps straight to the MLX local engine
    /// instead of the cloud-fallback chain used by the removed cloud engines.
    private static let removedLocalWhisperRawValue = "whisper"

    private static let purgedDefaultsKeys = [
        "googleCloudAPIKey",
        "serviceAccountConfigured",
        "geminiAudioModel",
        // WhisperKit (removed 2026-07-06; MLX is the local engine now).
        "whisperKitModel",
        "whisperKitUnloadAfterMinutes",
        "whisperkit_downloaded_models",
    ]

    static func run(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        migrateSelectedEngineIfNeeded(defaults: defaults)
        purgeRemovedArtifacts(defaults: defaults, fileManager: fileManager)
    }

    /// Pure mapping used by the launch migration and by settings import:
    /// WhisperKit moves to its direct replacement (MLX local); removed cloud
    /// engines fall back to a configured cloud engine, else local.
    static func migratedEngine(
        from stored: String,
        hasDeepgramKey: Bool,
        hasElevenLabsKey: Bool
    ) -> String {
        guard removedEngineRawValues.contains(stored) else { return stored }
        if stored == removedLocalWhisperRawValue {
            return TranscriptionEngine.mlxWhisper.rawValue
        }
        if hasDeepgramKey {
            return TranscriptionEngine.deepgram.rawValue
        }
        if hasElevenLabsKey {
            return TranscriptionEngine.elevenLabsScribe.rawValue
        }
        return TranscriptionEngine.mlxWhisper.rawValue
    }

    private static func migrateSelectedEngineIfNeeded(defaults: UserDefaults) {
        guard let stored = defaults.string(forKey: Constants.StorageKeys.transcriptionEngine),
            removedEngineRawValues.contains(stored)
        else {
            return
        }

        // Hint-based presence checks: this runs unprompted at launch, so it
        // must never be the reason the keychain consent dialog appears.
        let migrated = migratedEngine(
            from: stored,
            hasDeepgramKey: KeychainStore.hasValue(for: .deepgramAPIKey),
            hasElevenLabsKey: KeychainStore.hasValue(for: .elevenLabsAPIKey)
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

        deleteWhisperKitModelCaches(fileManager: fileManager)

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

    /// WhisperKit downloaded multi-GB CoreML models into shared HuggingFace
    /// cache roots. Deletion is surgical: only entries whose NAME contains
    /// "whisperkit" go — never a whole `huggingface` cache, which other tools
    /// share. Empty `argmaxinc`/`models`/`huggingface` parents left behind in
    /// Documents are pruned so the visible folder disappears too.
    static func deleteWhisperKitModelCaches(fileManager: FileManager = .default) {
        var searchRoots: [URL] = []
        if let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            searchRoots.append(cacheDir.appendingPathComponent("huggingface/hub"))
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            searchRoots.append(appSupport.appendingPathComponent("huggingface/hub"))
        }
        searchRoots.append(
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        )
        if let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            searchRoots.append(docDir.appendingPathComponent("huggingface/models/argmaxinc"))
        }

        var deletedAny = false
        for root in searchRoots {
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil
                )
            else { continue }
            for entry in entries where entry.lastPathComponent.lowercased().contains("whisperkit") {
                try? fileManager.removeItem(at: entry)
                deletedAny = true
                SapoLog.lifecycle.info("Deleted WhisperKit model cache")
            }
        }

        // Prune the now-empty Documents/huggingface chain (created by
        // WhisperKit itself, so it only ever held these models).
        if deletedAny, let docDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            var leaf = docDir.appendingPathComponent("huggingface/models/argmaxinc")
            for _ in 0..<3 {
                guard
                    let remaining = try? fileManager.contentsOfDirectory(atPath: leaf.path),
                    remaining.filter({ $0 != ".DS_Store" }).isEmpty
                else { break }
                try? fileManager.removeItem(at: leaf)
                leaf.deleteLastPathComponent()
            }
        }
    }
}
