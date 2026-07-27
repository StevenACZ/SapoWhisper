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
            writeEngineKey: { _, _ in true }
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
            writeEngineKey: { value, key in
                written[key] = value
                return true
            }
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

    func testImportFailsWhenTheKeychainRefusesTheAPIKeys() throws {
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

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in false }
        )
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))

        XCTAssertThrowsError(try manager.importDocument(document, sections: [.apiKeys])) { error in
            guard case SettingsTransferError.apiKeysNotStored(let count) = error else {
                return XCTFail("Expected apiKeysNotStored, got \(error)")
            }
            XCTAssertEqual(count, 2)
        }
    }

    func testImportSucceedsWhenTheKeychainStoresTheAPIKeys() throws {
        let legacyExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.2.0",
              "exportedAt": "2026-01-15T10:00:00Z",
              "apiKeys": {
                "deepgramAPIKey": "dg-legacy-key"
              }
            }
            """

        let suiteName = "test.sapowhisper.transfer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))

        XCTAssertNoThrow(try manager.importDocument(document, sections: [.apiKeys]))
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
            writeEngineKey: { _, _ in true }
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
            writeEngineKey: { _, _ in true }
        )
        let document = try manager.decodedDocument(from: try manager.encodedSettings())

        XCTAssertEqual(document.preferences?.audioUploadQuality, AudioUploadQuality.high.rawValue)
    }

    // MARK: - Hotkey import hardening

    /// A hand-edited or truncated export file can carry an out-of-range hotkey.
    /// `UInt32(_:)` traps on those, so the import must sanitize before it
    /// persists anything: an unvalidated value in UserDefaults bricks the next
    /// launch, and the only recovery is `defaults delete` from a terminal.
    func testImportSanitizesOutOfRangeHotkeyValues() throws {
        let corruptedExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.13.1",
              "exportedAt": "2026-07-26T10:00:00Z",
              "preferences": {
                "appLanguage": "es",
                "transcriptionLanguage": "es",
                "autoPaste": true,
                "playSound": true,
                "soundVolume": 1,
                "autoDuckingEnabled": false,
                "autoDuckingAmount": 0.8,
                "transcriptionEngine": "mlx_whisper",
                "deepgramTranscriptionMode": "nova3",
                "hotkeyKeyCode": -1,
                "hotkeyModifiers": -2048,
                "hotkeyDoubleTapModifier": -2048,
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

        // The import also reconfigures the shared hotkey manager, which writes
        // the standard suite; put the live combo back afterwards.
        let hotkeyManager = HotkeyManager.shared
        let liveTriggerKind = hotkeyManager.currentTriggerKind
        let liveKeyCode = hotkeyManager.currentKeyCode
        let liveModifiers = hotkeyManager.currentModifiers
        let liveDoubleTapModifier = hotkeyManager.currentDoubleTapModifier
        defer {
            hotkeyManager.updateConfiguration(
                triggerKind: liveTriggerKind,
                keyCode: liveKeyCode,
                modifiers: liveModifiers,
                doubleTapModifier: liveDoubleTapModifier
            )
        }

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )
        let document = try manager.decodedDocument(from: Data(corruptedExport.utf8))
        try manager.importDocument(document, sections: [.hotkey])

        XCTAssertEqual(
            defaults.integer(forKey: Constants.StorageKeys.hotkeyKeyCode),
            Int(Constants.Hotkey.defaultKeyCode)
        )
        XCTAssertEqual(
            defaults.integer(forKey: Constants.StorageKeys.hotkeyModifiers),
            Int(Constants.Hotkey.defaultModifiers)
        )
        XCTAssertEqual(
            defaults.integer(forKey: Constants.StorageKeys.hotkeyDoubleTapModifier),
            Int(Constants.Hotkey.defaultDoubleTapModifier)
        )
        XCTAssertEqual(hotkeyManager.currentKeyCode, Constants.Hotkey.defaultKeyCode)
        XCTAssertEqual(hotkeyManager.currentModifiers, Constants.Hotkey.defaultModifiers)
    }

    /// A valid file still lands unchanged — the sanitizer is a floor, not a
    /// filter that flattens real user hotkeys.
    func testImportKeepsValidHotkeyValues() throws {
        let validExport = """
            {
              "schemaVersion": 1,
              "appVersion": "2.13.1",
              "exportedAt": "2026-07-26T10:00:00Z",
              "preferences": {
                "appLanguage": "es",
                "transcriptionLanguage": "es",
                "autoPaste": true,
                "playSound": true,
                "soundVolume": 1,
                "autoDuckingEnabled": false,
                "autoDuckingAmount": 0.8,
                "transcriptionEngine": "mlx_whisper",
                "deepgramTranscriptionMode": "nova3",
                "hotkeyKeyCode": 0,
                "hotkeyModifiers": 256,
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

        let hotkeyManager = HotkeyManager.shared
        let liveTriggerKind = hotkeyManager.currentTriggerKind
        let liveKeyCode = hotkeyManager.currentKeyCode
        let liveModifiers = hotkeyManager.currentModifiers
        let liveDoubleTapModifier = hotkeyManager.currentDoubleTapModifier
        defer {
            hotkeyManager.updateConfiguration(
                triggerKind: liveTriggerKind,
                keyCode: liveKeyCode,
                modifiers: liveModifiers,
                doubleTapModifier: liveDoubleTapModifier
            )
        }

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )
        let document = try manager.decodedDocument(from: Data(validExport.utf8))
        try manager.importDocument(document, sections: [.hotkey])

        // 0 is kVK_ANSI_A, a key the recorder can genuinely capture.
        XCTAssertEqual(defaults.integer(forKey: Constants.StorageKeys.hotkeyKeyCode), 0)
        XCTAssertEqual(defaults.integer(forKey: Constants.StorageKeys.hotkeyModifiers), 256)
        XCTAssertEqual(hotkeyManager.currentKeyCode, 0)
        XCTAssertEqual(hotkeyManager.currentModifiers, 256)
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
