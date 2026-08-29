//
//  TranscriptPolishPromptBuilderTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class TranscriptPolishPromptBuilderTests: XCTestCase {

    private func makeSystem(
        outputLanguage: TranscriptPolishOutputLanguage = .sameAsInput,
        keyterms: [String] = [],
        replacements: [String: String] = [:],
        recentDictations: [String] = []
    ) -> String {
        TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola equipo",
            personalContext: "",
            outputLanguage: outputLanguage,
            keyterms: keyterms,
            replacements: replacements,
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

    /// The single adaptive contract: pure-filler deletion, repetition merging,
    /// dual-use words kept when meaningful, sacred numbers, and never
    /// inventing lists — the v6 rules validated on the 2026-07-04 bench
    /// against the production model (gpt-5.4-nano).
    func testAdaptiveContractRulesArePresent() {
        let system = makeSystem()

        XCTAssertTrue(system.contains("ALWAYS delete"))
        XCTAssertTrue(system.contains("como se dice"))
        XCTAssertTrue(system.contains("MERGE repetition"))
        XCTAssertTrue(system.contains("Dual-use words — delete only the filler or discourse use"))
        XCTAssertTrue(system.contains("Numbers are sacred"))
        XCTAssertTrue(system.contains("NEVER turn speech into bullet lists"))
        XCTAssertFalse(system.contains("Mode —"))
    }

    func testDualUseRecalibrationAndSameLanguageDictionaryExample() {
        let system = makeSystem()

        guard let alwaysRule = system.components(separatedBy: "\n").first(where: { $0.contains("ALWAYS delete") })
        else {
            return XCTFail("ALWAYS delete rule missing")
        }
        XCTAssertFalse(alwaysRule.contains("la verdad"))
        XCTAssertFalse(alwaysRule.contains("equis"))
        XCTAssertTrue(system.contains("la verdad es que ya funciona"))
        XCTAssertTrue(system.contains("Output (same language, dictionary has PeekOCR, BuenMouse, CHANGELOG)"))
        XCTAssertTrue(system.contains("Output (English, dictionary has PeekOCR, BuenMouse, CHANGELOG)"))
    }

    func testContextualFillersAreExcludedFromAlwaysDeleteRule() {
        let system = makeSystem()

        guard let alwaysRule = system.components(separatedBy: "\n").first(where: { $0.contains("ALWAYS delete") })
        else {
            return XCTFail("ALWAYS delete rule missing")
        }
        XCTAssertFalse(alwaysRule.contains("pues"))
        XCTAssertFalse(alwaysRule.contains("digamos"))
        XCTAssertFalse(alwaysRule.contains("se puede decir"))
    }

    func testContextualFillerContractIncludesDeleteExamples() {
        let system = makeSystem()

        XCTAssertTrue(system.contains("DELETE discourse \"Pues, seguimos con el tema\" → \"Seguimos con el tema\""))
        XCTAssertTrue(system.contains("DELETE hesitation \"El botón, digamos, debe verse bien\" → \"El botón debe verse bien\""))
        XCTAssertTrue(system.contains("DELETE speech-search \"El resultado es, se puede decir, estable\" → \"El resultado es estable\""))
    }

    func testContextualFillerContractIncludesKeepExamples() {
        let system = makeSystem()

        XCTAssertTrue(system.contains("KEEP causal \"No fui, pues estaba enfermo\""))
        XCTAssertTrue(system.contains("KEEP hypothetical \"Digamos que falla la red\""))
        XCTAssertTrue(system.contains("imperative \"Digamos la verdad\""))
        XCTAssertTrue(system.contains("KEEP epistemic qualification \"Se puede decir que mejoró, aunque falta medirlo\""))
    }

    /// Chunks 2+ of a long dictation carry the raw tail of their predecessor
    /// strictly as continuity context.
    func testPreviousChunkTailRenderedAsContextBlock() {
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: "hola equipo",
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:],
            previousChunkTail: "así terminaba el\nchunk anterior"
        )

        XCTAssertTrue(messages.system.contains("<transcript_continues_from>"))
        XCTAssertTrue(messages.system.contains("…así terminaba el chunk anterior"))
        XCTAssertTrue(messages.system.contains("never repeat it in your output"))
    }

    func testNoPreviousChunkTailOmitsBlock() {
        XCTAssertFalse(makeSystem().contains("<transcript_continues_from>"))
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

final class TranscriptChunkingTests: XCTestCase {

    func testShortTextStaysWhole() {
        let text = String(repeating: "Una frase corta. ", count: 20)  // ~340 chars
        XCTAssertEqual(TranscriptPostProcessor.splitIntoChunks(text), [text])
    }

    func testLongTextSplitsAtSentenceBoundaries() {
        let sentence = "Esta es una frase de prueba que ocupa espacio real en el dictado. "
        let text = String(repeating: sentence, count: 60).trimmingCharacters(in: .whitespaces)  // ~4k chars
        let chunks = TranscriptPostProcessor.splitIntoChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasSuffix("."), "chunk must end on a sentence boundary")
            XCTAssertLessThanOrEqual(chunk.count, TranscriptPostProcessor.chunkTargetCharacters + sentence.count)
        }
        // No content lost: chunks re-join into the original text (modulo the
        // whitespace trimmed at the seams).
        let rejoined = chunks.joined(separator: " ")
        XCTAssertEqual(
            rejoined.replacingOccurrences(of: " ", with: ""),
            text.replacingOccurrences(of: " ", with: "")
        )
    }

    /// Punctuation-less speech (some engines emit no enders) must still chunk:
    /// unchunked 5k+ inputs make small models summarize away real content.
    /// The fallback splits at whitespace, never mid-word.
    func testTextWithoutSentenceEndersChunksAtWordBoundaries() {
        let text = String(repeating: "palabras sin puntuacion ", count: 150)  // >3k chars, no enders
        let chunks = TranscriptPostProcessor.splitIntoChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        let vocabulary: Set<String> = ["palabras", "sin", "puntuacion"]
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, TranscriptPostProcessor.chunkTargetCharacters + 30)
            let tokens = chunk.split(separator: " ").map(String.init)
            XCTAssertTrue(
                tokens.allSatisfy(vocabulary.contains),
                "seams must fall on whitespace, not mid-word"
            )
        }
    }

    /// A period between digits or inside a filename is spoken content, not a
    /// sentence end: "24.7", "10.000", ".env", and "CLAUDE.md" must never be
    /// cut apart by a chunk seam (a mid-number seam loses the number).
    func testChunkSeamsNeverSplitNumbersOrFilenames() {
        let filler = String(repeating: "Relleno que ocupa espacio en el dictado real. ", count: 34)  // ~1.6k
        let sensitive = "El servidor corre 24.7 con menos de 10.000 tokens, revisa el .env y el CLAUDE.md de una vez. "
        let text = filler + sensitive + filler + sensitive + filler

        let chunks = TranscriptPostProcessor.splitIntoChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        for token in ["24.7", "10.000", ".env", "CLAUDE.md"] {
            let intactOccurrences = chunks.map { $0.components(separatedBy: token).count - 1 }.reduce(0, +)
            XCTAssertEqual(intactOccurrences, 2, "\(token) must stay whole inside a single chunk")
        }
    }

    /// A tiny tail (last sentence overflowing the target) merges back into the
    /// previous chunk instead of being polished alone without context.
    func testTinyTailChunkMergesIntoPreviousChunk() {
        let sentence = "Esta es una frase de prueba que ocupa espacio real en el dictado. "
        let text = String(repeating: sentence, count: 48) + "Listo."

        let chunks = TranscriptPostProcessor.splitIntoChunks(text)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertGreaterThanOrEqual(chunks.last?.count ?? 0, TranscriptPostProcessor.chunkTailMergeCharacters)
        XCTAssertTrue(chunks.last?.hasSuffix("Listo.") == true)
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
