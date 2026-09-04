//
//  VocabularyUsageMetricsTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class VocabularyUsageMetricsTests: XCTestCase {

    private func entry(
        text: String,
        duration: TimeInterval = 30,
        status: String = "completed"
    ) -> HistoryEntry {
        HistoryEntry(
            id: Int64.random(in: 1...1_000_000),
            timestamp: Date(),
            engine: "ElevenLabs Scribe v2",
            language: "es",
            duration: duration,
            text: text,
            rawText: text,
            audioPath: nil,
            status: status,
            aiStatus: "none",
            aiModel: nil,
            aiMode: nil,
            aiError: nil,
            isFavorite: false
        )
    }

    // MARK: - Words per minute

    func testAverageWordsPerMinuteAcrossEntries() {
        // 60 words in 1 min + 120 words in 1 min = 180 words / 2 min = 90 wpm
        let first = entry(text: Array(repeating: "word", count: 60).joined(separator: " "), duration: 60)
        let second = entry(text: Array(repeating: "word", count: 120).joined(separator: " "), duration: 60)
        XCTAssertEqual(VocabularyUsageCalculator.averageWordsPerMinute(entries: [first, second]), 90)
    }

    func testWordsPerMinuteSkipsShortFailedAndEmptyEntries() {
        let tooShort = entry(text: "uno dos tres", duration: 3)
        let failed = entry(text: "uno dos tres", duration: 30, status: "failed")
        let empty = entry(text: "", duration: 30)
        XCTAssertNil(VocabularyUsageCalculator.averageWordsPerMinute(entries: [tooShort, failed, empty]))
    }

    func testWordsPerMinuteNilWithoutEntries() {
        XCTAssertNil(VocabularyUsageCalculator.averageWordsPerMinute(entries: []))
    }

    // MARK: - Word-boundary counting

    func testOccurrencesRequireWordBoundaries() {
        let text = "print pr pr-test, pr. (pr) sprint"
        // "pr" inside "print"/"sprint" must not match; punctuation neighbors do.
        XCTAssertEqual(VocabularyUsageCalculator.occurrences(of: "pr", inLowercased: text), 4)
    }

    func testOccurrencesAreCountedAcrossTranscripts() {
        let transcripts = [
            "deploy sapowhisper now",
            "sapowhisper and sapowhisper again",
            "unrelated text",
        ]
        let counts = VocabularyUsageCalculator.termCounts(
            terms: ["SapoWhisper"],
            inLowercasedTranscripts: transcripts
        )
        XCTAssertEqual(counts["sapowhisper"], 3)
    }

    func testTermsWithSymbolsMatchLiterally() {
        let text = "edit .env and agents.md today"
        XCTAssertEqual(VocabularyUsageCalculator.occurrences(of: ".env", inLowercased: text), 1)
        XCTAssertEqual(VocabularyUsageCalculator.occurrences(of: "agents.md", inLowercased: text), 1)
    }

    // MARK: - Top terms

    func testTopTermsSortedAndCapped() {
        let transcripts = [
            "alpha alpha alpha beta beta gamma delta",
            "alpha beta gamma",
        ]
        let top = VocabularyUsageCalculator.topTerms(
            keyterms: ["alpha", "beta", "gamma", "delta"],
            replacementValues: [],
            inLowercasedTranscripts: transcripts
        )
        XCTAssertEqual(top.map(\.term), ["alpha", "beta", "gamma"])
        XCTAssertEqual(top.map(\.count), [4, 3, 2])
    }

    func testTopTermsIncludeReplacementValuesWithoutDuplicates() {
        let transcripts = ["claude code helps claude code"]
        let top = VocabularyUsageCalculator.topTerms(
            keyterms: ["Claude Code"],
            replacementValues: ["Claude Code"],
            inLowercasedTranscripts: transcripts
        )
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top.first?.count, 2)
    }

    func testTopTermsOmitUnusedTerms() {
        let top = VocabularyUsageCalculator.topTerms(
            keyterms: ["nunca-dicho"],
            replacementValues: [],
            inLowercasedTranscripts: ["hola mundo"]
        )
        XCTAssertTrue(top.isEmpty)
    }

    // MARK: - Countable transcripts

    func testCountableTranscriptsFilterAndLowercase() {
        let completed = entry(text: "Hola SapoWhisper")
        let failed = entry(text: "ignorada", status: "failed")
        let empty = entry(text: "")
        let transcripts = VocabularyUsageCalculator.countableTranscripts(from: [completed, failed, empty])
        XCTAssertEqual(transcripts, ["hola sapowhisper"])
    }
}
