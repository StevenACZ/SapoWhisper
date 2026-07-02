//
//  TranscriptPolishPromptBuilderTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class TranscriptPolishPromptBuilderTests: XCTestCase {

    private var workProfile: PromptProfile {
        PromptContextManager.defaultPrompts.first { $0.id == TranscriptPolishMode.work.rawValue }!
    }

    private func makeSystem(
        outputLanguage: TranscriptPolishOutputLanguage = .sameAsInput,
        keyterms: [String] = [],
        replacements: [String: String] = [:],
        memoryContext: AIPolishMemoryContext? = nil,
        recentDictations: [String] = []
    ) -> String {
        TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola equipo",
            promptProfile: workProfile,
            personalContext: "",
            outputLanguage: outputLanguage,
            keyterms: keyterms,
            replacements: replacements,
            memoryContext: memoryContext,
            recentDictations: recentDictations
        ).system
    }

    /// The dictionary must show every canonical spelling exactly once:
    /// keyterms plus replacement VALUES (the corrected forms), never the
    /// misheard replacement keys.
    func testDictionaryMergesKeytermsAndReplacementValues() {
        let system = makeSystem(
            keyterms: ["PeekOCR", "git push"],
            replacements: ["buen mouse": "BuenMouse", "kit push": "git push"]
        )

        XCTAssertTrue(system.contains("PeekOCR, git push, BuenMouse"))
        XCTAssertTrue(system.contains("never translated into the output language"))
        XCTAssertTrue(system.contains("Never insert a dictionary term"))
    }

    /// Replacement pairs surface as explicit mishearing context so the model
    /// can map STT distortions the deterministic pass did not catch.
    func testKnownMishearingsListReplacementPairs() {
        let system = makeSystem(replacements: ["cloud code": "Claude Code"])

        XCTAssertTrue(system.contains("Known mishearings (heard => intended)"))
        XCTAssertTrue(system.contains("\"cloud code\" => \"Claude Code\""))
    }

    func testAcceptedMemoryCorrectionsMergeIntoMishearings() {
        let accepted = AIPolishCorrectionSuggestion(
            id: "deep comment->git commit",
            from: "deep comment",
            to: "git commit",
            status: .accepted,
            occurrences: 3,
            confidence: 0.9,
            firstSeen: Date(timeIntervalSince1970: 1_782_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_782_000_000)
        )
        let system = makeSystem(
            memoryContext: AIPolishMemoryContext(detectedMode: .technical, acceptedCorrections: [accepted])
        )

        XCTAssertTrue(system.contains("\"deep comment\" => \"git commit\""))
        XCTAssertTrue(system.contains("Detected domain: technical"))
    }

    func testEmptyVocabularyMarksDictionaryAsSkippable() {
        let system = makeSystem()
        XCTAssertTrue(system.contains("(empty — the user has no saved vocabulary; skip this section)"))
        XCTAssertFalse(system.contains("Known mishearings"))
    }

    /// Recent dictations arrive oldest-first from the context builder and are
    /// framed strictly as disambiguation context.
    func testRecentDictationsRenderedAsContextBlock() {
        let system = makeSystem(
            recentDictations: ["Primero revisa PeekOCR.", "Ahora los\natajos de teclado."]
        )

        XCTAssertTrue(system.contains("<recent_dictations>"))
        XCTAssertTrue(system.contains("- Primero revisa PeekOCR."))
        XCTAssertTrue(system.contains("- Ahora los atajos de teclado."))
        XCTAssertTrue(system.contains("Never copy their content into the output"))
    }

    func testNoRecentDictationsOmitsBlock() {
        XCTAssertFalse(makeSystem().contains("<recent_dictations>"))
    }

    func testFinalCheckNamesTheOutputLanguage() {
        XCTAssertTrue(
            makeSystem(outputLanguage: .german).contains("output language = German"))
        XCTAssertTrue(
            makeSystem(outputLanguage: .sameAsInput).contains("output language = same as transcript"))
    }

    func testUserMessageWrapsTranscriptInDelimiters() {
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola equipo",
            promptProfile: workProfile,
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:]
        )

        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptStartDelimiter))
        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptEndDelimiter))
        XCTAssertTrue(messages.user.contains("hola equipo"))
    }
}

final class RecentDictationContextTests: XCTestCase {

    private func entry(
        id: Int64,
        minutesAgo: Double,
        text: String,
        status: String = "completed",
        now: Date
    ) -> HistoryEntry {
        HistoryEntry(
            id: id,
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            engine: "whisper",
            language: "auto",
            duration: 5,
            text: text,
            rawText: text,
            audioPath: nil,
            status: status,
            aiStatus: "applied",
            aiModel: nil,
            aiMode: nil,
            aiError: nil,
            isFavorite: false
        )
    }

    func testFiltersOldFailedAndEmptyEntries() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let lines = RecentDictationContext.contextLines(
            from: [
                entry(id: 4, minutesAgo: 2, text: "reciente y válida", now: now),
                entry(id: 3, minutesAgo: 5, text: "", now: now),
                entry(id: 2, minutesAgo: 8, text: "fallida", status: "failed", now: now),
                entry(id: 1, minutesAgo: 45, text: "demasiado vieja", now: now),
            ],
            now: now
        )

        XCTAssertEqual(lines, ["reciente y válida"])
    }

    func testKeepsNewestEntriesOldestFirst() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let entries = (1...6).map { index in
            entry(
                id: Int64(10 - index),
                minutesAgo: Double(index),
                text: "dictado \(index)",
                now: now
            )
        }

        let lines = RecentDictationContext.contextLines(from: entries, now: now)

        XCTAssertEqual(lines, ["dictado 4", "dictado 3", "dictado 2", "dictado 1"])
    }

    func testHonorsTotalCharacterBudget() {
        let now = Date(timeIntervalSince1970: 1_782_000_000)
        let long = String(repeating: "palabra ", count: 60)  // ~480 chars → clipped to ≤260
        let entries = [
            entry(id: 3, minutesAgo: 1, text: long, now: now),
            entry(id: 2, minutesAgo: 2, text: long, now: now),
            entry(id: 1, minutesAgo: 3, text: long, now: now),
        ]

        let lines = RecentDictationContext.contextLines(from: entries, now: now)
        let total = lines.reduce(0) { $0 + $1.count }

        XCTAssertLessThanOrEqual(total, RecentDictationContext.maxTotalCharacters)
        XCTAssertEqual(lines.count, 2)
    }

    func testSanitizedLineFlattensAndClipsOnWordBoundary() {
        let flattened = RecentDictationContext.sanitizedLine("línea uno\nlínea   dos")
        XCTAssertEqual(flattened, "línea uno línea dos")

        let clipped = RecentDictationContext.sanitizedLine(String(repeating: "palabra ", count: 60))
        XCTAssertLessThanOrEqual(clipped.count, RecentDictationContext.maxEntryCharacters + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertFalse(clipped.contains("palabr…"))
    }
}
