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

    func testRemovedEngineMigratesToWhisperWithoutKeys() {
        XCTAssertEqual(
            EnginePortfolioMigration.migratedEngine(from: "gemini_audio", hasDeepgramKey: false, hasElevenLabsKey: false),
            TranscriptionEngine.whisperLocal.rawValue
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

        let manager = SettingsTransferManager(defaults: defaults)
        let document = try manager.decodedDocument(from: Data(legacyExport.utf8))
        try manager.importDocument(document, sections: [.engine])

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.transcriptionEngine),
            TranscriptionEngine.whisperLocal.rawValue
        )
        // Google fields are ignored end to end: nothing writes the legacy keys.
        XCTAssertNil(defaults.string(forKey: "googleCloudAPIKey"))
        XCTAssertNil(defaults.string(forKey: "geminiAudioModel"))
    }

    // MARK: - History filter buckets

    func testEngineFilterBucketsRemovedEnginesUnderOther() {
        XCTAssertTrue(EngineFilter.other.matches("Google Chirp 3"))
        XCTAssertTrue(EngineFilter.other.matches("Apple (Online)"))
        XCTAssertTrue(EngineFilter.other.matches("Gemini Audio · Flash"))
        XCTAssertFalse(EngineFilter.other.matches("Deepgram Nova-3"))
        XCTAssertTrue(EngineFilter.elevenLabs.matches("ElevenLabs Scribe Realtime v2"))
        XCTAssertTrue(EngineFilter.whisper.matches("Whisper (Local)"))
    }
}
