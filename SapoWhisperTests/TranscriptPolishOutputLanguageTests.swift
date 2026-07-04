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

    /// Every explicit target must inject its English name into the LIVE
    /// prompt (the builder's language rule) so the polisher actually
    /// translates — asserting on the production prompt, not on a copy.
    func testExplicitTargetsBuildTranslationInstruction() {
        for language in TranscriptPolishOutputLanguage.allCases where language != .sameAsInput {
            guard let englishName = language.englishName else {
                XCTFail("\(language.rawValue) is missing an English name")
                continue
            }
            let messages = TranscriptPolishPromptBuilder.makeMessages(
                rawText: "hola, ¿cómo estás?",
                personalContext: "",
                outputLanguage: language,
                keyterms: [],
                replacements: [:]
            )
            XCTAssertTrue(
                messages.system.contains("Write the ENTIRE output in \(englishName)"),
                "\(language.rawValue) prompt should target \(englishName)"
            )
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
    /// so a hosted-provider round-trip fits, capped at 20s (per chunk).
    func testHostedPolishTimeoutScalesWithTranscriptLength() {
        func hostedTimeout(_ count: Int) -> UInt64 {
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: count, duration: nil, usesLocalBudget: false
            )
        }
        XCTAssertEqual(hostedTimeout(0), 5)
        XCTAssertEqual(hostedTimeout(400), 5)
        XCTAssertEqual(hostedTimeout(1400), 10)
        XCTAssertEqual(hostedTimeout(2814), 17)
        XCTAssertEqual(hostedTimeout(100_000), 20)
    }

    /// The overlay countdown consumes this same total: for chunked
    /// transcripts it must be the SUM of per-chunk budgets — showing the
    /// single-call cap made the HUD hit 0 while the polish was still running.
    func testTotalPolishBudgetSumsChunkBudgets() {
        let text = String(repeating: "Una frase corta que termina bien. ", count: 200)
        let chunks = TranscriptPostProcessor.splitIntoChunks(text)
        XCTAssertGreaterThan(chunks.count, 1)

        let expected = chunks.reduce(UInt64(0)) { total, chunk in
            total
                + TranscriptPostProcessor.polishTimeout(
                    forCharacterCount: chunk.count, duration: nil, usesLocalBudget: false
                )
        }
        let total = TranscriptPostProcessor.totalPolishBudget(
            forText: text, duration: nil, usesLocalBudget: false
        )
        XCTAssertEqual(total, expected)
        XCTAssertGreaterThan(
            total,
            TranscriptPostProcessor.polishTimeout(
                forCharacterCount: text.count, duration: nil, usesLocalBudget: false
            )
        )
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
