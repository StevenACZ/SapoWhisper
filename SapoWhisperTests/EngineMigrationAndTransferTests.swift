//
//  EngineMigrationAndTransferTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
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

    func testSettingsExportSanitizesProviderURLs() throws {
        let suiteName = "test.sapowhisper.transfer-url-export.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "https://user:secret@transcription.example/v1?token=private#fragment",
            forKey: Constants.StorageKeys.localAIServerBaseURL
        )
        defaults.set(
            "https://user:secret@polish.example/v1?token=private#fragment",
            forKey: Constants.StorageKeys.aiPolishCustomBaseURL
        )

        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )
        let document = try manager.decodedDocument(from: manager.encodedSettings())

        XCTAssertEqual(document.preferences?.localAIServerBaseURL, "https://transcription.example/v1")
        XCTAssertEqual(document.preferences?.aiPolishCustomBaseURL, "https://polish.example/v1")
        let encoded = try manager.encodedSettings()
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private"))
    }

    func testSettingsImportSanitizesProviderURLs() throws {
        let suiteName = "test.sapowhisper.transfer-url-import.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        document.preferences?.localAIServerBaseURL =
            "https://user:secret@transcription.example/v1?token=private#fragment"
        document.preferences?.aiPolishCustomBaseURL =
            "https://user:secret@polish.example/v1?token=private#fragment"

        try manager.importDocument(document, sections: [.engine, .aiPolish])

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL),
            "https://transcription.example/v1"
        )
        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL),
            "https://polish.example/v1"
        )
        XCTAssertEqual(
            PolishProviderConfiguration.storedBaseURLInput(
                for: .custom,
                defaults: defaults,
                allowLegacyFallback: false
            ),
            "https://polish.example/v1"
        )
    }

    func testSettingsTransferOmitsInvalidProviderURLValues() throws {
        let suiteName = "test.sapowhisper.transfer-invalid-urls.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("private-value-that-is-not-a-url", forKey: Constants.StorageKeys.localAIServerBaseURL)
        defaults.set("another-private-value", forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
        let manager = SettingsTransferManager(
            defaults: defaults,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in true }
        )

        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        XCTAssertNil(document.preferences?.localAIServerBaseURL)
        XCTAssertNil(document.preferences?.aiPolishCustomBaseURL)

        defaults.set("https://safe.example/v1", forKey: Constants.StorageKeys.localAIServerBaseURL)
        defaults.set("https://safe-polish.example/v1", forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
        document.preferences?.localAIServerBaseURL = "not a provider URL"
        document.preferences?.aiPolishCustomBaseURL = "still not a provider URL"
        try manager.importDocument(document, sections: [.engine, .aiPolish])

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL),
            "https://safe.example/v1"
        )
        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL),
            "https://safe-polish.example/v1"
        )
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

    func testImportNormalizesLegacyRealtimeBackupsWithoutChangingPrimaryRealtimeModes() throws {
        for (legacy, batch, primary) in [
            ("deepgram_flux_live", "deepgram_nova3", TranscriptionEngine.elevenLabsScribe),
            ("elevenlabs_scribe_realtime", "elevenlabs_scribe_batch", TranscriptionEngine.deepgram),
        ] {
            try withBackupTransferFixture { defaults, manager in
                var document = try manager.decodedDocument(from: manager.encodedSettings())
                document.unsetPreferenceKeys = nil
                var preferences = try XCTUnwrap(document.preferences)
                preferences.fallbackTranscriptionEngine = legacy
                preferences.transcriptionEngine = primary.rawValue
                preferences.deepgramTranscriptionMode = DeepgramTranscriptionMode.fluxLive.rawValue
                preferences.elevenLabsTranscriptionMode = ElevenLabsTranscriptionMode.scribeV2Realtime.rawValue
                document.preferences = preferences
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let imported = try manager.decodedDocument(from: encoder.encode(document))

                try manager.importDocument(imported, sections: [.engine])

                XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.fallbackTranscriptionEngine), batch)
                XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.transcriptionEngine), primary.rawValue)
                XCTAssertEqual(
                    defaults.string(forKey: Constants.StorageKeys.deepgramTranscriptionMode),
                    DeepgramTranscriptionMode.fluxLive.rawValue
                )
                XCTAssertEqual(
                    defaults.string(forKey: Constants.StorageKeys.elevenLabsTranscriptionMode),
                    ElevenLabsTranscriptionMode.scribeV2Realtime.rawValue
                )
            }
        }
    }

    func testExportNormalizesObsoleteBackupWithoutMutatingPrimaryModesOrSourcePreferences() throws {
        for (legacy, batch, primary) in [
            ("deepgram_flux_live", "deepgram_nova3", TranscriptionEngine.elevenLabsScribe),
            ("elevenlabs_scribe_realtime", "elevenlabs_scribe_batch", TranscriptionEngine.deepgram),
        ] {
            try withBackupTransferFixture { defaults, manager in
                defaults.set(legacy, forKey: Constants.StorageKeys.fallbackTranscriptionEngine)
                defaults.set(primary.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
                defaults.set(DeepgramTranscriptionMode.fluxLive.rawValue, forKey: Constants.StorageKeys.deepgramTranscriptionMode)
                defaults.set(
                    ElevenLabsTranscriptionMode.scribeV2Realtime.rawValue, forKey: Constants.StorageKeys.elevenLabsTranscriptionMode)

                let exported = try manager.decodedDocument(from: manager.encodedSettings())
                let preferences = try XCTUnwrap(exported.preferences)

                XCTAssertEqual(preferences.fallbackTranscriptionEngine, batch)
                XCTAssertEqual(preferences.transcriptionEngine, primary.rawValue)
                XCTAssertEqual(preferences.deepgramTranscriptionMode, DeepgramTranscriptionMode.fluxLive.rawValue)
                XCTAssertEqual(preferences.elevenLabsTranscriptionMode, ElevenLabsTranscriptionMode.scribeV2Realtime.rawValue)
                XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.fallbackTranscriptionEngine), legacy)
                XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.transcriptionEngine), primary.rawValue)
                XCTAssertEqual(
                    defaults.string(forKey: Constants.StorageKeys.deepgramTranscriptionMode),
                    DeepgramTranscriptionMode.fluxLive.rawValue
                )
                XCTAssertEqual(
                    defaults.string(forKey: Constants.StorageKeys.elevenLabsTranscriptionMode),
                    ElevenLabsTranscriptionMode.scribeV2Realtime.rawValue
                )
            }
        }
    }

    private func withBackupTransferFixture(
        _ body: (UserDefaults, SettingsTransferManager) throws -> Void
    ) throws {
        let suite = "test.transfer.batch-backup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = SettingsTransferManager(
            defaults: defaults,
            vocabularyManager: VocabularyManager(fileURL: directory.appendingPathComponent("vocabulary.json")),
            promptContextManager: PromptContextManager(fileURL: directory.appendingPathComponent("context.json")),
            backupDirectory: directory.appendingPathComponent("backups"),
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                XCTFail("Engine preference transfer must not write credentials")
                return false
            }
        )
        try body(defaults, manager)
    }

    func testPortablePreferencesRoundTripAndHistoryOptIn() throws {
        let sourceSuite = "test.transfer.source.\(UUID().uuidString)"
        let targetSuite = "test.transfer.target.\(UUID().uuidString)"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let target = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }
        source.set("deepgram_nova3", forKey: Constants.StorageKeys.fallbackTranscriptionEngine)
        source.set(2048, forKey: Constants.StorageKeys.historyAudioMaxMB)
        source.set(90, forKey: Constants.StorageKeys.historyAutoDeleteDays)
        source.set("compact", forKey: Constants.StorageKeys.aiPolishMode)
        source.set(30, forKey: Constants.StorageKeys.aiPolishMinDuration)
        source.set(15, forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes)
        PolishProviderConfiguration.setStoredModel("portable-model", for: .custom, defaults: source)
        PolishProviderConfiguration.setStoredBaseURLInput("https://portable.example/v1", for: .custom, defaults: source)
        let exporter = SettingsTransferManager(defaults: source, readEngineKey: { _ in nil }, writeEngineKey: { _, _ in true })
        let importer = SettingsTransferManager(defaults: target, readEngineKey: { _ in nil }, writeEngineKey: { _, _ in true })
        let document = try exporter.decodedDocument(from: exporter.encodedSettings())
        XCTAssertFalse(importer.defaultImportSections(for: document).contains(.history))
        XCTAssertNil(document.apiKeys)
        try importer.importDocument(document, sections: [.engine, .aiPolish])
        XCTAssertNil(target.object(forKey: Constants.StorageKeys.historyAutoDeleteDays))
        try importer.importDocument(document, sections: [.history])
        for key in [Constants.StorageKeys.fallbackTranscriptionEngine, Constants.StorageKeys.aiPolishMode] {
            XCTAssertEqual(source.string(forKey: key), target.string(forKey: key))
        }
        for key in [
            Constants.StorageKeys.historyAudioMaxMB, Constants.StorageKeys.historyAutoDeleteDays,
            Constants.StorageKeys.aiPolishMinDuration, Constants.StorageKeys.mlxWhisperUnloadAfterMinutes,
        ] {
            XCTAssertEqual(source.integer(forKey: key), target.integer(forKey: key))
        }
        XCTAssertEqual(PolishProviderConfiguration.storedModel(for: .custom, defaults: target), "portable-model")
        XCTAssertEqual(PolishProviderConfiguration.storedBaseURLInput(for: .custom, defaults: target), "https://portable.example/v1")
        XCTAssertNil(target.object(forKey: Constants.StorageKeys.selectedMicrophone))
    }

    func testInvalidDocumentDoesNotPartiallyMutatePreferencesOrKeys() throws {
        let suite = "test.transfer.validation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var keyWrites = 0
        let manager = SettingsTransferManager(
            defaults: defaults, readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                keyWrites += 1
                return true
            })
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        document.preferences?.autoPaste = false
        document.preferences?.historyAudioMaxMB = -1
        document.apiKeys = SettingsTransferAPIKeys(deepgramAPIKey: "fixture", elevenLabsAPIKey: nil)
        let before = defaults.dictionaryRepresentation() as NSDictionary
        XCTAssertThrowsError(try manager.importDocument(document, sections: [.behavior, .apiKeys]))
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertEqual(keyWrites, 0)
        document.preferences?.historyAudioMaxMB = 1024
        document.vocabulary = nil
        XCTAssertThrowsError(try manager.importDocument(document, sections: [.behavior, .vocabulary]))
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        document.schemaVersion = 99
        XCTAssertThrowsError(try manager.importDocument(document, sections: [.behavior]))
    }

    func testVocabularyCombinePreservesLocalConflictsAndIsIdempotent() {
        let existing = VocabularySnapshot(
            keyterms: ["Local"], replacements: ["term": "Local"], includeReplacementTargetsInRecognitionHints: false)
        let incoming = VocabularySnapshot(
            keyterms: [" Imported ", "Local"], replacements: [" TERM ": "Incoming", "new": "New"],
            includeReplacementTargetsInRecognitionHints: true)
        let combined = VocabularyImportMode.combine.snapshot(importing: incoming, into: existing)
        XCTAssertEqual(combined.keyterms, ["Local", "Imported"])
        XCTAssertEqual(combined.replacements, ["term": "Local", "new": "New"])
        XCTAssertEqual(combined.includeReplacementTargetsInRecognitionHints, false)
        XCTAssertEqual(VocabularyImportMode.combine.snapshot(importing: incoming, into: combined), combined)
        XCTAssertEqual(VocabularyImportMode.replace.snapshot(importing: incoming, into: existing), incoming)
    }

    func testAbsentPortableFieldsPreserveDestinationValues() throws {
        let suite = "test.transfer.optional.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SettingsTransferManager(defaults: defaults, readEngineKey: { _ in nil }, writeEngineKey: { _, _ in true })
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        document.preferences?.fallbackTranscriptionEngine = nil
        document.preferences?.mlxWhisperUnloadAfterMinutes = nil
        defaults.set("deepgram_flux_live", forKey: Constants.StorageKeys.fallbackTranscriptionEngine)
        defaults.set(60, forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes)
        try manager.importDocument(document, sections: [.engine])
        XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.fallbackTranscriptionEngine), "deepgram_flux_live")
        XCTAssertEqual(defaults.integer(forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes), 60)
    }

    func testFailedContextWriteRollsBackVocabularyBeforePreferencesChange() throws {
        let suite = "test.transfer.rollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let vocabularyURL = directory.appendingPathComponent("vocabulary.json")
        let contextURL = directory.appendingPathComponent("context.json")
        let backups = directory.appendingPathComponent("backups")
        let vocabulary = VocabularyManager(fileURL: vocabularyURL)
        let context = PromptContextManager(fileURL: contextURL)
        let originalVocabulary = VocabularySnapshot(keyterms: ["Original"], replacements: ["term": "Original"])
        let originalContext = PromptContextSnapshot(personalContext: PersonalPromptContext(details: "Original context"))
        try vocabulary.replacePersisting(with: originalVocabulary)
        try context.replacePersisting(with: originalContext)
        let originalVocabularyBytes = try Data(contentsOf: vocabularyURL)
        defaults.set(true, forKey: Constants.StorageKeys.autoPaste)
        var keyWrites = 0
        let manager = SettingsTransferManager(
            defaults: defaults, vocabularyManager: vocabulary, promptContextManager: context, backupDirectory: backups,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                keyWrites += 1
                return true
            }
        )
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        document.preferences?.autoPaste = false
        document.vocabulary = VocabularySnapshot(keyterms: ["Incoming"], replacements: [:])
        document.promptContext = PromptContextSnapshot(personalContext: PersonalPromptContext(details: "Incoming context"))
        document.apiKeys = SettingsTransferAPIKeys(deepgramAPIKey: "fixture-secret", elevenLabsAPIKey: nil)
        try FileManager.default.removeItem(at: contextURL)
        try FileManager.default.createDirectory(at: contextURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try manager.importDocument(document, sections: [.behavior, .vocabulary, .promptContext, .apiKeys], vocabularyMode: .replace)
        ) { error in
            guard case SettingsTransferError.importFileWriteFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(defaults.bool(forKey: Constants.StorageKeys.autoPaste))
        XCTAssertEqual(vocabulary.snapshot().keyterms, ["Original"])
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(contentsOf: vocabularyURL)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: originalVocabularyBytes) as? NSDictionary)
        XCTAssertEqual(context.snapshot().personalContext, originalContext.personalContext)
        XCTAssertEqual(keyWrites, 0)
        let backupFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(backupFiles.count, 1)
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(backupFiles.first).path)
        XCTAssertEqual((backupAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: backups.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let backupData = try Data(contentsOf: XCTUnwrap(backupFiles.first))
        let backup = try manager.decodedDocument(from: backupData)
        XCTAssertEqual(backup.vocabulary?.keyterms, ["Original"])
        XCTAssertEqual(backup.promptContext?.personalContext, originalContext.personalContext)
        XCTAssertEqual(backup.preferences?.autoPaste, true)
        XCTAssertNil(backup.apiKeys)
        XCTAssertFalse(String(decoding: backupData, as: UTF8.self).contains("fixture-secret"))
    }

    func testBackupFailurePreventsAllImportMutations() throws {
        let suite = "test.transfer.backup-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data().write(to: blockedDirectory)
        let vocabulary = VocabularyManager(fileURL: directory.appendingPathComponent("vocabulary.json"))
        let context = PromptContextManager(fileURL: directory.appendingPathComponent("context.json"))
        let manager = SettingsTransferManager(
            defaults: defaults, vocabularyManager: vocabulary, promptContextManager: context, backupDirectory: blockedDirectory,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                XCTFail("Unexpected key write")
                return true
            }
        )
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.unsetPreferenceKeys = nil
        document.preferences?.autoPaste = false
        document.vocabulary = VocabularySnapshot(keyterms: ["Incoming"], replacements: [:])
        let before = vocabulary.snapshot()
        XCTAssertThrowsError(try manager.importDocument(document, sections: [.behavior, .vocabulary]))
        XCTAssertNil(defaults.object(forKey: Constants.StorageKeys.autoPaste))
        XCTAssertEqual(vocabulary.snapshot(), before)
    }

    func testBackupRestoresExplicitlyUnsetPortablePreferences() throws {
        let suite = "test.transfer.unset-restore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = SettingsTransferManager(
            defaults: defaults,
            vocabularyManager: VocabularyManager(fileURL: directory.appendingPathComponent("vocabulary.json")),
            promptContextManager: PromptContextManager(fileURL: directory.appendingPathComponent("context.json")),
            backupDirectory: directory.appendingPathComponent("backups"),
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                XCTFail("Unexpected key write")
                return false
            }
        )
        var incoming = try manager.decodedDocument(from: manager.encodedSettings())
        incoming.unsetPreferenceKeys = nil
        incoming.preferences?.localAIServerBaseURL = "https://new.example/v1"
        incoming.preferences?.localAIServerModel = "new-stt-model"
        incoming.preferences?.polishProviderModels = [PolishEndpoint.custom.rawValue: "new-polish-model"]
        incoming.preferences?.polishProviderBaseURLs = [PolishEndpoint.custom.rawValue: "https://polish.example/v1"]
        let backupURL = try manager.importDocument(incoming, sections: [.engine, .aiPolish])
        XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL), "https://new.example/v1")
        let scopedModelKey = Constants.StorageKeys.aiPolishEndpointModelPrefix + PolishEndpoint.custom.rawValue
        let scopedURLKey = Constants.StorageKeys.aiPolishEndpointBaseURLPrefix + PolishEndpoint.custom.rawValue
        XCTAssertEqual(defaults.string(forKey: scopedModelKey), "new-polish-model")
        let backup = try manager.decodedDocument(from: Data(contentsOf: backupURL))
        XCTAssertTrue(try XCTUnwrap(backup.unsetPreferenceKeys).contains(scopedURLKey))
        try manager.importDocument(backup, sections: [.engine])
        XCTAssertNil(defaults.object(forKey: Constants.StorageKeys.localAIServerBaseURL))
        XCTAssertNil(defaults.object(forKey: Constants.StorageKeys.localAIServerModel))
        XCTAssertEqual(defaults.string(forKey: scopedModelKey), "new-polish-model")
        XCTAssertEqual(defaults.string(forKey: scopedURLKey), "https://polish.example/v1")
        try manager.importDocument(backup, sections: [.aiPolish])
        for key in [scopedModelKey, scopedURLKey, Constants.StorageKeys.aiPolishCustomBaseURL, Constants.StorageKeys.aiPolishModel] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        var legacyBackup = backup
        legacyBackup.unsetPreferenceKeys = nil
        defaults.set("https://keep.example/v1", forKey: Constants.StorageKeys.localAIServerBaseURL)
        try manager.importDocument(legacyBackup, sections: [.engine])
        XCTAssertEqual(defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL), "https://keep.example/v1")
    }

    func testUnsetMetadataRejectsSensitiveDeviceAndUnknownKeysBeforeChanges() throws {
        let suite = "test.transfer.unset-security.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let backups = directory.appendingPathComponent("backups")
        let manager = SettingsTransferManager(
            defaults: defaults,
            vocabularyManager: VocabularyManager(fileURL: directory.appendingPathComponent("vocabulary.json")),
            promptContextManager: PromptContextManager(fileURL: directory.appendingPathComponent("context.json")),
            backupDirectory: backups,
            readEngineKey: { _ in nil },
            writeEngineKey: { _, _ in
                XCTFail("Unexpected key write")
                return false
            }
        )
        var document = try manager.decodedDocument(from: manager.encodedSettings())
        document.preferences?.autoPaste = false
        defaults.set(true, forKey: Constants.StorageKeys.autoPaste)
        for key in [
            Constants.StorageKeys.deepgramAPIKey, Constants.StorageKeys.keychainStoredKeyHints,
            Constants.StorageKeys.selectedMicrophone, Constants.StorageKeys.pinPrimaryMicrophone,
            Constants.StorageKeys.onboardingComplete, "unknown", Constants.StorageKeys.aiPolishEndpointBaseURLPrefix + "unknown",
        ] {
            document.unsetPreferenceKeys = [key]
            XCTAssertThrowsError(try manager.importDocument(document, sections: [.behavior]))
            XCTAssertTrue(defaults.bool(forKey: Constants.StorageKeys.autoPaste))
            XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        }
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
