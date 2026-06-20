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

    func testRecordsTechnicalTermsAndCorrectionSuggestions() {
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

        let context = manager.contextPacket(
            rawText: "haz deep commit",
            correctedText: "haz git commit",
            keyterms: ["git commit", "CLAUDE.md", "REST API"],
            replacements: [:],
            now: now
        )
        let suggestions = manager.snapshot().suggestions

        XCTAssertEqual(context.detectedMode, .technical)
        XCTAssertTrue(context.topDailyTerms.contains("git commit"))
        XCTAssertTrue(context.topWeeklyTerms.contains("CLAUDE.md"))
        XCTAssertTrue(suggestions.contains { $0.from == "deep commit" && $0.to == "git commit" })
        XCTAssertTrue(suggestions.contains { $0.from == "cloud md" && $0.to == "CLAUDE.md" })
        XCTAssertTrue(suggestions.contains { $0.from == "ali test" && $0.to == "REST API" })
    }

    func testAcceptedAndRejectedSuggestionsAffectPromptContext() throws {
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

        let context = manager.contextPacket(
            rawText: "haz deep comment",
            correctedText: "haz git commit",
            keyterms: ["git commit", "Claude Code"],
            replacements: [:],
            now: now
        )

        XCTAssertTrue(context.acceptedCorrections.contains { $0.from == "deep comment" })
        XCTAssertFalse(context.pendingCorrections.contains { $0.from == "cloud code" })
        XCTAssertTrue(context.promptBlock.contains("\"deep comment\" -> \"git commit\""))
        XCTAssertFalse(context.promptBlock.contains("\"cloud code\" -> \"Claude Code\""))
    }

    func testPromptBuilderIncludesCompactLocalMemoryContext() {
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

        let context = manager.contextPacket(
            rawText: "revisa cloud md",
            correctedText: "revisa CLAUDE.md",
            keyterms: ["CLAUDE.md", "git commit"],
            replacements: [:],
            now: now
        )
        let profile = PromptProfile(
            id: "automatic",
            name: "Clean-up",
            details: "test",
            instruction: "Keep it literal.",
            forcesEnglish: false
        )
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "revisa cloud md",
            promptProfile: profile,
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: ["CLAUDE.md", "git commit"],
            replacements: [:],
            memoryContext: context
        )

        XCTAssertLessThan(context.promptBlock.count, 1_800)
        XCTAssertTrue(messages.system.contains("<local_learning_memory>"))
        XCTAssertTrue(messages.system.contains("Detected writing mode: technical"))
        XCTAssertTrue(messages.system.contains("Candidate corrections"))
        XCTAssertTrue(messages.system.contains("right side is the canonical wording"))
        XCTAssertEqual(messages.user, "revisa cloud md")
    }

    func testTermRankingIgnoresShortAIAndFileStemNoise() {
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

        let context = manager.contextPacket(
            rawText: "la IA debe revisar agents md",
            correctedText: "la IA debe revisar AGENTS.md",
            keyterms: ["AGENTS.md"],
            replacements: [:],
            now: now
        )

        XCTAssertTrue(context.topDailyTerms.contains("AGENTS.md"))
        XCTAssertFalse(context.topDailyTerms.contains("IA"))
        XCTAssertFalse(context.topDailyTerms.contains("AGENTS"))
        XCTAssertFalse(context.topDailyTerms.contains(".md"))
        XCTAssertFalse(context.topDailyTerms.contains("git de"))
        XCTAssertFalse(context.topDailyTerms.contains("git para"))
    }
}
