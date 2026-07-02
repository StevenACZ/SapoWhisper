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

    /// With an explicit target the system prompt must demand a full
    /// translation; with same-as-input it must pin the transcript language.
    func testExplicitTargetBuildsFullTranslationRule() {
        let translated = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola, ¿cómo estás?",
            personalContext: "",
            outputLanguage: .english,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertTrue(translated.system.contains("Write the ENTIRE output in English"))
        XCTAssertTrue(translated.system.contains("output language = English"))

        let literal = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola, ¿cómo estás?",
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertTrue(literal.system.contains("same dominant language as the transcript"))
        XCTAssertTrue(literal.system.contains("output language = same as transcript"))
    }

}

final class TranscriptPolishTimeoutTests: XCTestCase {

    /// Short dictations keep the snappy 5s budget; long transcripts scale up
    /// so a hosted-provider round-trip fits, capped at 20s.
    func testHostedPolishTimeoutScalesWithTranscriptLength() {
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 0), 5)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 400), 5)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 1400), 10)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 2814), 17)
        XCTAssertEqual(TranscriptPostProcessor.polishTimeout(forCharacterCount: 100_000), 20)
    }

    func testLocalPolishTimeoutUsesLargerBudget() {
        let localConfiguration = PolishProviderConfiguration(
            endpoint: .custom,
            baseURL: URL(string: "http://local-ai.local:8081/v1")!,
            model: "qwen3.6-35b-a3b",
            apiKey: ""
        )

        XCTAssertEqual(
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: 400,
                duration: 36,
                configuration: localConfiguration
            ),
            23
        )
        XCTAssertEqual(
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: 100_000,
                duration: 600,
                configuration: localConfiguration
            ),
            120
        )
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

        let memoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pre-polish-memory-\(UUID().uuidString).json")
        let memoryManager = AIPolishMemoryManager(fileURL: memoryURL)
        let processor = TranscriptPostProcessor(vocabularyManager: vocabularyManager, memoryManager: memoryManager)
        let result = await processor.process(rawText: "open sap o whisper and claude dot md")

        XCTAssertEqual(result.status, .none)
        XCTAssertEqual(result.rawText, "open SapoWhisper and CLAUDE.md")
        XCTAssertEqual(result.finalText, "open SapoWhisper and CLAUDE.md")
    }
}
