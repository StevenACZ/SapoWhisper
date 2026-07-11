//
//  WhisperHallucinationFilterTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

/// The hallucination strings below are real engine outputs reproduced from
/// history audio against faster-whisper large-v3-turbo (2026-07-11).
final class WhisperHallucinationFilterTests: XCTestCase {

    private let vocabulary = [
        "SapoWhisper", "Claude Code", "GitHub", "Jellyfin", "Xcode",
        "CLAUDE.md", "AGENTS.md", ".md", ".env", "Sapo", "QA",
    ]

    // MARK: - Repetition loops

    func testCollapsesSingleTokenLoop() {
        let loop = "CTK214, " + Array(repeating: ".tk214,", count: 20).joined(separator: " ")
        let result = WhisperHallucinationFilter.collapsingRepetitionLoops(loop)
        XCTAssertTrue(result.collapsed)
        XCTAssertEqual(result.text, "CTK214, .tk214")
    }

    func testCollapsedLoopWithNonVocabularyTokenStaysSpeech() {
        let loop = "CTK214, " + Array(repeating: ".tk214,", count: 20).joined(separator: " ")
        let outcome = WhisperHallucinationFilter.evaluate(loop, vocabularyTerms: vocabulary)
        XCTAssertEqual(outcome, .speech("CTK214, .tk214"))
    }

    func testCollapsesAlternatingCycleLoop() {
        let loop = "Sapo.md, " + Array(repeating: "Yellyfin, CLAUDE.md,", count: 8).joined(separator: " ")
        let result = WhisperHallucinationFilter.collapsingRepetitionLoops(loop)
        XCTAssertTrue(result.collapsed)
        XCTAssertEqual(result.text, "Sapo.md, Yellyfin, CLAUDE.md")
    }

    func testThreeWordRepeatsAreNotCollapsed() {
        let speech = "no, no, no, eso no era lo que quería"
        let result = WhisperHallucinationFilter.collapsingRepetitionLoops(speech)
        XCTAssertFalse(result.collapsed)
        XCTAssertEqual(result.text, speech)
    }

    func testNormalSentencePassesUntouched() {
        let speech = "Dale, muchas gracias, eso sería todo."
        XCTAssertEqual(
            WhisperHallucinationFilter.evaluate(speech, vocabularyTerms: vocabulary),
            .speech(speech)
        )
    }

    func testFiveIdenticalTokensCollapseToOne() {
        let outcome = WhisperHallucinationFilter.evaluate(
            "jem, jem, jem, jem, jem.", vocabularyTerms: vocabulary)
        XCTAssertEqual(outcome, .speech("jem"))
    }

    // MARK: - Vocabulary echo

    func testGlossaryEchoLoopBecomesNonSpeech() {
        // Real breath-only take: the decoder read the glossary prompt back,
        // fusing terms ("Sapo.md") and distorting spellings ("Yellyfin").
        let echo = "Sapo.md, " + Array(repeating: "CLAUDE.md,", count: 16).joined(separator: " ")
        let outcome = WhisperHallucinationFilter.evaluate(echo, vocabularyTerms: vocabulary)
        XCTAssertEqual(outcome, .nonSpeech(reason: "vocabulary echo after loop collapse"))
    }

    func testAlternatingGlossaryEchoBecomesNonSpeech() {
        let echo = "Sapo.md, " + Array(repeating: "Yellyfin, CLAUDE.md,", count: 8).joined(separator: " ")
        let outcome = WhisperHallucinationFilter.evaluate(echo, vocabularyTerms: vocabulary)
        XCTAssertEqual(outcome, .nonSpeech(reason: "vocabulary echo after loop collapse"))
    }

    func testDictatingVocabularyTermsWithoutLoopIsSpeech() {
        // Echo detection only arms after a repetition collapse — listing two
        // known terms is legitimate dictation.
        let speech = "GitHub, Jellyfin"
        XCTAssertEqual(
            WhisperHallucinationFilter.evaluate(speech, vocabularyTerms: vocabulary),
            .speech(speech)
        )
    }

    func testSingleTermDictationIsSpeech() {
        XCTAssertEqual(
            WhisperHallucinationFilter.evaluate("Jellyfin.", vocabularyTerms: vocabulary),
            .speech("Jellyfin.")
        )
    }

    func testEchoDetectionRequiresVocabulary() {
        let echo = "Sapo.md, " + Array(repeating: "CLAUDE.md,", count: 16).joined(separator: " ")
        let outcome = WhisperHallucinationFilter.evaluate(echo, vocabularyTerms: [])
        XCTAssertEqual(outcome, .speech("Sapo.md, CLAUDE.md"))
    }

    // MARK: - Punctuation debris

    func testPunctuationOnlyTextIsNonSpeech() {
        for junk in [". .", ".", "…", ", ,"] {
            let outcome = WhisperHallucinationFilter.evaluate(junk, vocabularyTerms: vocabulary)
            guard case .nonSpeech = outcome else {
                return XCTFail("expected nonSpeech for \(junk), got \(outcome)")
            }
        }
    }

    func testFreePhraseHallucinationIsNotThisFiltersJob() {
        // "Thank you." on silence is killed by the server-side VAD filter;
        // in text form it is indistinguishable from real speech.
        XCTAssertEqual(
            WhisperHallucinationFilter.evaluate("Thank you.", vocabularyTerms: vocabulary),
            .speech("Thank you.")
        )
    }
}
