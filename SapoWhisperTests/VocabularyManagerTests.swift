//
//  VocabularyManagerTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class VocabularyManagerTests: XCTestCase {

    /// A manager backed by a throwaway temp file, so tests never read or write
    /// the user's real vocabulary.json.
    private func makeManager() -> VocabularyManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-test-\(UUID().uuidString).json")
        return VocabularyManager(fileURL: url)
    }

    // MARK: - Replacements

    func testApplyingReplacementsIsWholeWordCaseInsensitive() {
        let manager = makeManager()
        manager.addReplacement(from: "kubernetes", to: "Kubernetes")
        XCTAssertEqual(manager.applyingReplacements(to: "uso kubernetes a diario"), "uso Kubernetes a diario")
        // Whole-word only: a longer token must be left untouched.
        XCTAssertEqual(manager.applyingReplacements(to: "kubernetesx"), "kubernetesx")
    }

    func testApplyingReplacementsHandlesSpokenPunctuation() {
        let manager = makeManager()
        manager.addReplacement(from: "deep.gram", to: "Deepgram")
        // "deep gram" (the dot spoken as a space) still maps to the canonical form.
        XCTAssertEqual(manager.applyingReplacements(to: "abrí deep gram hoy"), "abrí Deepgram hoy")
    }

    func testLongerReplacementKeysWinFirst() {
        let manager = makeManager()
        manager.addReplacement(from: "git", to: "Git")
        manager.addReplacement(from: "git hub", to: "GitHub")
        // The longer key is applied first, so "git hub" becomes "GitHub" whole.
        XCTAssertEqual(manager.applyingReplacements(to: "abrí git hub ayer"), "abrí GitHub ayer")
    }

    // MARK: - Recognition keyterm payload

    func testKeytermPayloadKeepsSavedTermsFirst() {
        let manager = makeManager()
        manager.addKeyterm("GitHub")
        let payload = manager.recognitionKeytermPayload(maxCount: 10, maxLength: 50, maxWords: nil)
        XCTAssertEqual(payload.terms.first, "GitHub")
    }

    func testKeytermPayloadDropsOverLongTerms() {
        let manager = makeManager()
        let longTerm = String(repeating: "a", count: 60)
        manager.addKeyterm(longTerm)
        let payload = manager.recognitionKeytermPayload(maxCount: 100, maxLength: 50, maxWords: nil)
        XCTAssertFalse(payload.terms.contains(longTerm))
    }

    func testKeytermPayloadHonorsMaxCount() {
        let manager = makeManager()
        manager.addKeyterm("alpha")
        manager.addKeyterm("beta")
        manager.addKeyterm("gamma")
        let payload = manager.recognitionKeytermPayload(maxCount: 2, maxLength: 50, maxWords: nil)
        XCTAssertEqual(payload.terms.count, 2)
        XCTAssertGreaterThan(payload.droppedCount, 0)
    }

    // MARK: - Limits and query items

    func testElevenLabsLimitViolationsCountsOverLongTerms() {
        let manager = makeManager()
        manager.addKeyterm(String(repeating: "a", count: 60))  // over batch (50) and realtime (20)
        manager.addKeyterm(String(repeating: "b", count: 25))  // over realtime (20) only
        let violations = manager.elevenLabsLimitViolations()
        XCTAssertEqual(violations.batch, 1)
        XCTAssertEqual(violations.realtime, 2)
    }

    func testDeepgramKeytermQueryParamIsSingular() {
        let manager = makeManager()
        manager.addKeyterm("Kubernetes")
        // AGENTS.md: Deepgram Nova-3 uses the singular `keyterm` query param.
        XCTAssertEqual(manager.keytermQueryItems().first?.name, "keyterm")
    }
}
