//
//  EngineMigrationAndTransferTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class EngineMigrationAndTransferTests: XCTestCase {

    // MARK: - Engine migration mapping (§3.0)

    func testRemovedEngineMigratesToDeepgramWhenKeyPresent() {
        XCTAssertEqual(
            EnginePortfolioMigration.migratedEngine(from: "apple", hasDeepgramKey: true, hasElevenLabsKey: true),
            TranscriptionEngine.deepgram.rawValue
        )
    }

    func testRemovedEngineMigratesToElevenLabsWhenOnlyThatKeyPresent() {
        XCTAssertEqual(
            EnginePortfolioMigration.migratedEngine(from: "google", hasDeepgramKey: false, hasElevenLabsKey: true),
            TranscriptionEngine.elevenLabsScribe.rawValue
        )
    }

    func testRemovedEngineMigratesToLocalWhisperWithoutKeys() {
        XCTAssertEqual(
            EnginePortfolioMigration.migratedEngine(from: "gemini_audio", hasDeepgramKey: false, hasElevenLabsKey: false),
            TranscriptionEngine.mlxWhisper.rawValue
        )
    }

    /// WhisperKit (raw "whisper") maps straight to its MLX replacement even
    /// when cloud keys exist — the user had chosen a LOCAL engine.
    func testRemovedWhisperKitAlwaysMigratesToMLX() {
        XCTAssertEqual(
            EnginePortfolioMigration.migratedEngine(from: "whisper", hasDeepgramKey: true, hasElevenLabsKey: true),
            TranscriptionEngine.mlxWhisper.rawValue
        )
    }

    func testCurrentEnginesPassThroughUnchanged() {
        for engine in TranscriptionEngine.allCases {
            XCTAssertEqual(
                EnginePortfolioMigration.migratedEngine(from: engine.rawValue, hasDeepgramKey: true, hasElevenLabsKey: true),
                engine.rawValue
            )
        }
    }

    // MARK: - Settings import (old export files)

    func testOldExportWithGoogleFieldsDecodesAndMigratesEngine() throws {
        let legacyExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.1.0",
              "exportedAt": "2025-11-02T10:00:00Z",
              "preferences": {
                "appLanguage": "es",
                "transcriptionLanguage": "es",
                "autoPaste": true,
                "playSound": true,
                "soundVolume": 1,
                "autoDuckingEnabled": false,
                "autoDuckingAmount": 0.8,
                "transcriptionEngine": "apple",
                "whisperKitModel": "openai_whisper-small",
                "deepgramTranscriptionMode": "nova3",
                "geminiAudioModel": "gemini-3.1-flash-lite",
                "hotkeyKeyCode": 49,
                "hotkeyModifiers": 2048,
                "audioGain": 1,
                "aiPolishEnabled": false,
                "aiPolishMode": "automatic",
                "aiPolishOutputLanguage": "same_as_input"
              },
              "apiKeys": {
                "googleCloudAPIKey": "AIza-legacy-key"
              }
            }
            """

        let suiteName = "test.sapowhisper.transfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in }
        )
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))
        try manager.importDocument(document, sections: [.engine])

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.transcriptionEngine),
            TranscriptionEngine.mlxWhisper.rawValue
        )
        // Google fields are ignored end to end: nothing writes the legacy keys.
        XCTAssertNil(defaults.string(forKey: "googleCloudAPIKey"))
        XCTAssertNil(defaults.string(forKey: "geminiAudioModel"))
    }

    func testLegacyAPIKeysImportToKeychainNotDefaults() throws {
        let legacyExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.2.0",
              "exportedAt": "2026-01-15T10:00:00Z",
              "apiKeys": {
                "deepgramAPIKey": "dg-legacy-key",
                "elevenLabsAPIKey": "el-legacy-key"
              }
            }
            """

        let suiteName = "test.sapowhisper.transfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var written: [KeychainStore.Key: String] = [:]
        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { value, key in written[key] = value }
        )
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))
        XCTAssertTrue(manager.availableSections(in: document).contains(.apiKeys))
        XCTAssertFalse(manager.defaultImportSections(for: document).contains(.apiKeys))

        try manager.importDocument(document, sections: [.apiKeys])

        XCTAssertEqual(written[.deepgramAPIKey], "dg-legacy-key")
        XCTAssertEqual(written[.elevenLabsAPIKey], "el-legacy-key")
        XCTAssertNil(defaults.string(forKey: Constants.StorageKeys.deepgramAPIKey))
        XCTAssertNil(defaults.string(forKey: Constants.StorageKeys.elevenLabsAPIKey))
    }

    func testOldExportWithoutAudioUploadQualityImportsMediumDefault() throws {
        let legacyExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.2.0",
              "exportedAt": "2026-01-15T10:00:00Z",
              "preferences": {
                "appLanguage": "es",
                "transcriptionLanguage": "es",
                "autoPaste": true,
                "playSound": true,
                "soundVolume": 1,
                "autoDuckingEnabled": false,
                "autoDuckingAmount": 0.8,
                "transcriptionEngine": "whisper",
                "whisperKitModel": "openai_whisper-small",
                "deepgramTranscriptionMode": "nova3",
                "hotkeyKeyCode": 49,
                "hotkeyModifiers": 2048,
                "audioGain": 1,
                "aiPolishEnabled": false,
                "aiPolishMode": "automatic",
                "aiPolishOutputLanguage": "same_as_input"
              }
            }
            """

        let suiteName = "test.sapowhisper.transfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in }
        )
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))
        try manager.importDocument(document, sections: [.audio])

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.audioUploadQuality),
            AudioUploadQuality.medium.rawValue
        )
    }

    func testSettingsExportIncludesAudioUploadQuality() throws {
        let suiteName = "test.sapowhisper.transfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AudioUploadQuality.high.rawValue, forKey: Constants.StorageKeys.audioUploadQuality)

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in }
        )
        let document = try manager.decodedDocument(from: try manager.encodedSettings())

        XCTAssertEqual(document.preferences?.audioUploadQuality, AudioUploadQuality.high.rawValue)
    }

    // MARK: - History filter buckets

    func testEngineFilterBucketsRemovedEnginesUnderOther() {
        XCTAssertTrue(EngineFilter.other.matches("Google Chirp 3"))
        XCTAssertTrue(EngineFilter.other.matches("Apple (Online)"))
        XCTAssertTrue(EngineFilter.other.matches("Gemini Audio · Flash"))
        XCTAssertFalse(EngineFilter.other.matches("Deepgram Nova-3"))
        XCTAssertTrue(EngineFilter.elevenLabs.matches("ElevenLabs Scribe Realtime v2"))
        XCTAssertTrue(EngineFilter.whisper.matches("Whisper (Local)"))
        XCTAssertTrue(EngineFilter.localAI.matches("Local AI Server · Systran/faster-whisper-small"))
        XCTAssertFalse(EngineFilter.other.matches("Local AI Server · Systran/faster-whisper-small"))
    }
}
