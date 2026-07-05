//
//  AIPolishMemoryManagerTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class AIPolishMemoryManagerTests: XCTestCase {

    private func makeManager() -> AIPolishMemoryManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-polish-memory-\(UUID().uuidString).json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return AIPolishMemoryManager(fileURL: url, calendar: calendar)
    }

    func testRecordsCorrectionSuggestionsWithoutLearningKeyterms() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)  // 2026-02-20 UTC

        manager.record(
            observedRawText: "haz deep commit de los cambios en cloud md y revisa el ali test",
            correctedText: "haz git commit de los cambios en CLAUDE.md y revisa el REST API",
            finalText: "Haz `git commit` de los cambios en `CLAUDE.md` y revisa el REST API.",
            status: .applied,
            keyterms: ["git commit", "CLAUDE.md", "REST API"],
            replacements: [:],
            now: now
        )

        let snapshot = manager.snapshot()
        let suggestions = snapshot.suggestions

        XCTAssertTrue(snapshot.terms.isEmpty)
        XCTAssertTrue(suggestions.contains { $0.from == "deep commit" && $0.to == "git commit" })
        XCTAssertTrue(suggestions.contains { $0.from == "cloud md" && $0.to == "CLAUDE.md" })
        XCTAssertTrue(suggestions.contains { $0.from == "ali test" && $0.to == "REST API" })
    }

    func testAcceptedAndRejectedSuggestionsAffectReplacementPairs() throws {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "haz deep comment y abre cloud code",
            correctedText: "haz git commit y abre Claude Code",
            finalText: "Haz `git commit` y abre Claude Code.",
            status: .applied,
            keyterms: ["git commit", "Claude Code"],
            replacements: [:],
            now: now
        )

        let suggestions = manager.snapshot().suggestions
        let gitSuggestion = try XCTUnwrap(suggestions.first { $0.from == "deep comment" })
        let claudeSuggestion = try XCTUnwrap(suggestions.first { $0.from == "cloud code" })

        XCTAssertEqual(manager.acceptSuggestion(id: gitSuggestion.id)?.status, .accepted)
        XCTAssertEqual(manager.rejectSuggestion(id: claudeSuggestion.id)?.status, .rejected)

        let pairs = manager.acceptedReplacementPairs()

        XCTAssertEqual(pairs["deep comment"], "git commit")
        XCTAssertNil(pairs["cloud code"])
    }

    func testRecordsDynamicDomainSuggestionsFromAcceptedPolish() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "abre clauco y compara con ditgram",
            correctedText: "abre clauco y compara con ditgram",
            finalText: "Abre Claude Code y compara con Deepgram.",
            status: .applied,
            keyterms: ["Claude Code", "Deepgram"],
            replacements: [:],
            now: now
        )

        let suggestions = manager.snapshot().suggestions
        XCTAssertTrue(suggestions.contains { $0.from == "clauco" && $0.to == "Claude Code" })
        XCTAssertTrue(suggestions.contains { $0.from == "ditgram" && $0.to == "Deepgram" })
    }

    /// A correctly-spelled fragment of a term ("push", "Code") must never be
    /// proposed as a correction source: applied as a whole-word replacement it
    /// would rewrite normal prose (every plain "push" becoming "git push").
    /// Only distortions of the full term qualify.
    func testFragmentSourcesNeverBecomeSuggestions() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "haz push a la rama y abre Code para revisar",
            correctedText: "haz push a la rama y abre Code para revisar",
            finalText: "Haz git push a la rama y abre Claude Code para revisar.",
            status: .applied,
            keyterms: ["git push", "Claude Code"],
            replacements: [:],
            now: now
        )

        let suggestions = manager.snapshot().suggestions
        XCTAssertFalse(suggestions.contains { $0.from.lowercased() == "push" })
        XCTAssertFalse(suggestions.contains { $0.from.lowercased() == "code" })
    }

    func testDynamicSuggestionsAvoidAmbiguousShortNearMatches() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "abre Code y revisa el archivo",
            correctedText: "abre Code y revisa el archivo",
            finalText: "Abre Codex y revisa el archivo.",
            status: .applied,
            keyterms: ["Codex"],
            replacements: [:],
            now: now
        )

        XCTAssertFalse(manager.snapshot().suggestions.contains { $0.to == "Codex" })
    }

    func testPromptBuilderIncludesAcceptedCorrectionsAsMishearings() throws {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)
        for index in 0..<30 {
            manager.record(
                observedRawText: "revisa term\(index).md y haz deep commit",
                correctedText: "revisa term\(index).md y haz git commit",
                finalText: "Revisa `term\(index).md` y haz `git commit`.",
                status: .applied,
                keyterms: ["git commit", "term\(index).md"],
                replacements: [:],
                now: now
            )
        }
        let suggestion = try XCTUnwrap(
            manager.snapshot().suggestions.first { $0.from == "deep commit" && $0.to == "git commit" }
        )
        manager.acceptSuggestion(id: suggestion.id)

        // The processor merges accepted pairs into the replacements dict
        // before calling the builder — mirror that here.
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "revisa cloud md",
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: ["CLAUDE.md", "git commit"],
            replacements: manager.acceptedReplacementPairs()
        )

        XCTAssertTrue(messages.system.contains("Known mishearings (heard => intended)"))
        XCTAssertTrue(messages.system.contains("\"deep commit\" => \"git commit\""))
        XCTAssertFalse(messages.system.contains("Candidate corrections"))
        XCTAssertFalse(messages.system.contains("Top terms"))
        XCTAssertFalse(messages.system.contains("\"cloud md\" => \"CLAUDE.md\""))
        XCTAssertTrue(messages.user.contains("revisa cloud md"))
        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptStartDelimiter))
        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptEndDelimiter))
    }

    func testDoesNotLearnOrPromptKeytermSuggestions() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "la IA debe revisar agents md",
            correctedText: "la IA debe revisar AGENTS.md",
            finalText: "La IA debe revisar `AGENTS.md` y no aprender .md suelto, git de o git para.",
            status: .applied,
            keyterms: ["AGENTS.md"],
            replacements: [:],
            now: now
        )

        let snapshot = manager.snapshot()

        XCTAssertTrue(snapshot.terms.isEmpty)
        XCTAssertTrue(manager.acceptedReplacementPairs().isEmpty)
    }

    func testFailedPolishDoesNotLearnKeytermsOrCorrections() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "actualizaste legends.md y Claude Code.md",
            correctedText: "actualizaste legends.md y Claude Code.md",
            finalText: "Actualizaste legends.md y Claude Code.md.",
            status: .failed,
            keyterms: ["AGENTS.md", "Claude Code"],
            replacements: [:],
            now: now
        )

        let snapshot = manager.snapshot()

        XCTAssertTrue(snapshot.terms.isEmpty)
        XCTAssertFalse(snapshot.suggestions.contains { $0.from == "legends.md" })
    }

    func testAgentsConfusionCanCreateReviewableSuggestionWhenCorrected() {
        let manager = makeManager()
        let now = Date(timeIntervalSince1970: 1_771_430_400)

        manager.record(
            observedRawText: "actualizaste legends.md",
            correctedText: "actualizaste AGENTS.md",
            finalText: "Actualizaste `AGENTS.md`.",
            status: .applied,
            keyterms: ["AGENTS.md"],
            replacements: [:],
            now: now
        )

        XCTAssertTrue(
            manager.snapshot().suggestions.contains { suggestion in
                suggestion.from == "legends.md" && suggestion.to == "AGENTS.md"
            })
    }
}
