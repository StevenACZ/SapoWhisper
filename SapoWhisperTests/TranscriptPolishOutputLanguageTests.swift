//
//  TranscriptPolishOutputLanguageTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class TranscriptPolishOutputLanguageTests: XCTestCase {

    /// Raw values are persisted in UserDefaults and in exported settings
    /// JSON, so the pre-expansion values must keep decoding forever.
    func testLegacyRawValuesStillDecode() {
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "same_as_input"), .sameAsInput)
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "spanish"), .spanish)
        XCTAssertEqual(TranscriptPolishOutputLanguage(rawValue: "english"), .english)
    }

    func testOnlySameAsInputSkipsTranslation() {
        XCTAssertFalse(TranscriptPolishOutputLanguage.sameAsInput.requiresTranslation)
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            XCTAssertTrue(language.requiresTranslation, "\(language.rawValue) should require translation")
        }
    }

    /// Every explicit target must inject its English name into the prompt so
    /// the polisher actually translates, and must mark the override explicit.
    func testExplicitTargetsBuildTranslationInstruction() {
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            guard let englishName = language.englishName else {
                XCTFail("\(language.rawValue) is missing an English name")
                continue
            }
            XCTAssertTrue(
                language.promptInstruction.contains("Write the final text in \(englishName)"),
                "\(language.rawValue) prompt should target \(englishName)"
            )
            XCTAssertTrue(language.promptInstruction.contains("translate ALL of it"))
        }
        XCTAssertNil(TranscriptPolishOutputLanguage.sameAsInput.englishName)
    }

    /// The language verifier needs an ISO code for every explicit target.
    func testExplicitTargetsExposeNLLanguageCode() {
        XCTAssertNil(TranscriptPolishOutputLanguage.sameAsInput.nlLanguageCode)
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            XCTAssertNotNil(language.nlLanguageCode, "\(language.rawValue) is missing an NL language code")
        }
    }
}

final class TranscriptPolishTimeoutTests: XCTestCase {

    /// Short dictations keep the snappy 5s budget; long transcripts scale up
    /// so a translation round-trip fits, capped at 20s.
    func testPolishTimeoutScalesWithTranscriptLength() {
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 0), 5)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 400), 5)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 1400), 10)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 2814), 17)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 100_000), 20)
    }
}

final class TranscriptPrePolishCorrectionTests: XCTestCase {

    func testProcessAppliesVocabularyCorrectionsWhenAIPolishIsDisabled() async {
        let key = Constants.StorageKeys.aiPolishEnabled
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let vocabularyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-polish-vocab-\(UUID().uuidString).json")
        let vocabularyManager = VocabularyManager(fileURL: vocabularyURL)
        vocabularyManager.addKeyterm("SapoWhisper")
        vocabularyManager.addKeyterm("CLAUDE.md")

        let processor = TranscriptPostProcessor(vocabularyManager: vocabularyManager)
        let result = await processor.process(rawText: "open sap o whisper and claude dot md")

        XCTAssertEqual(result.status, .none)
        XCTAssertEqual(result.rawText, "open SapoWhisper and CLAUDE.md")
        XCTAssertEqual(result.finalText, "open SapoWhisper and CLAUDE.md")
    }
}
