//
//  TranscriptPostProcessor.swift
//  SapoWhisper
//

import Foundation
import NaturalLanguage
import os

final class TranscriptPostProcessor {
    private static let maximumFidelityAttempts = 3

    private struct GuardedPolishResponse: Sendable {
        let response: PolishResponse
        let cleanedText: String
        let blockedInstructionResponse: Bool
    }

    /// Result of polishing one chunk. A chunk that fails, times out, or gets
    /// blocked salvages to its OWN raw text so the other chunks keep their
    /// polish — a single bad chunk must not raw-fallback the whole dictation.
    private struct ChunkOutcome: Sendable {
        let text: String
        let applied: Bool
        let blocked: Bool
        let failureDetail: String?
        let model: String?
    }

    /// L10: per-chunk budget for the polish call (including the one
    /// translation retry). Hosted providers keep the snappy 5s-20s budget;
    /// local/LAN models get a larger budget because first-token latency and
    /// small-model reasoning can be much slower.
    static func polishTimeout(
        forCharacterCount count: Int,
        duration: TimeInterval?,
        configuration: PolishProviderConfiguration?
    ) -> UInt64 {
        polishTimeout(
            forCharacterCount: count,
            duration: duration,
            usesLocalBudget: configuration?.usesLocalTimeoutBudget == true
        )
    }

    static func polishTimeout(
        forCharacterCount count: Int,
        duration: TimeInterval?,
        usesLocalBudget: Bool
    ) -> UInt64 {
        if usesLocalBudget {
            let characterExtra = UInt64(max(0, count - 300) / 120)
            let durationExtra = UInt64(max(0, Int((duration ?? 0) - 10)) / 8)
            return min(20 + characterExtra + durationExtra, 120)
        }

        let base: UInt64 = 5
        let extra = UInt64(max(0, count - 400) / 200)
        return min(base + extra, 20)
    }

    /// Whole-step budget: the sum of per-chunk budgets after chunking. The
    /// overlay countdown must use this same function — showing the unchunked
    /// cap made the HUD hit 0 while a chunked polish was still legitimately
    /// running.
    static func totalPolishBudget(
        forText text: String,
        duration: TimeInterval?,
        usesLocalBudget: Bool
    ) -> UInt64 {
        let chunks = splitIntoChunks(text)
        let chunkDuration = duration.map { $0 / Double(chunks.count) }
        return chunks.reduce(UInt64(0)) { total, chunk in
            total
                + polishTimeout(
                    forCharacterCount: chunk.count,
                    duration: chunkDuration,
                    usesLocalBudget: usesLocalBudget
                )
        }
    }

    private let polisher: OpenAICompatiblePolisher
    private let vocabularyManager: VocabularyManager
    private let memoryManager: AIPolishMemoryManager
    private let recentDictationsProvider: () -> [String]

    init(
        polisher: OpenAICompatiblePolisher = OpenAICompatiblePolisher(),
        vocabularyManager: VocabularyManager = .shared,
        memoryManager: AIPolishMemoryManager = .shared,
        recentDictationsProvider: @escaping () -> [String] = {
            RecentDictationContext.contextLines(
                from: TranscriptionHistoryManager.shared.fetchEntries(limit: 10)
            )
        }
    ) {
        self.polisher = polisher
        self.vocabularyManager = vocabularyManager
        self.memoryManager = memoryManager
        self.recentDictationsProvider = recentDictationsProvider
    }

    func process(
        rawText: String,
        duration: TimeInterval? = nil
    ) async -> TranscriptAIResult {
        let signpostState = SapoSignpost.begin(SapoSignpost.Name.polish)
        defer { SapoSignpost.end(SapoSignpost.Name.polish, state: signpostState) }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return makeResult(rawText: rawText, finalText: trimmed, status: .none, startedAt: startedAt)
        }
        let recognitionCorrectedText =
            vocabularyManager
            .applyingRecognitionCorrections(to: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = recognitionCorrectedText.isEmpty ? trimmed : recognitionCorrectedText
        let keyterms = vocabularyManager.keyterms
        let replacements = vocabularyManager.replacements

        func finish(
            finalText: String,
            status: TranscriptAIStatus,
            model: String? = nil,
            mode: String? = nil,
            error: String? = nil
        ) -> TranscriptAIResult {
            let result = makeResult(
                rawText: transcript,
                finalText: finalText,
                status: status,
                model: model,
                mode: mode,
                error: error,
                startedAt: startedAt
            )
            memoryManager.record(
                observedRawText: trimmed,
                correctedText: transcript,
                finalText: result.finalText,
                status: result.status,
                keyterms: keyterms,
                replacements: replacements
            )
            return result
        }

        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled else {
            return finish(finalText: transcript, status: .none)
        }

        guard !PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults) else {
            SapoLog.ai.info("AI polish skipped reason=offline-hosted-provider")
            return finish(finalText: transcript, status: .none)
        }

        guard let configuration = PolishProviderConfiguration.current() else {
            // Enabled but no usable provider: dictation must never block on
            // polish, so the raw transcript ships untouched.
            SapoLog.ai.info("AI polish skipped reason=not-configured")
            return finish(finalText: transcript, status: .none)
        }

        let outputLanguage = Self.configuredOutputLanguage(defaults: defaults)

        // Accepted correction suggestions are canonical pairs too: they join
        // the user's replacements so polish and translation preserve them.
        let mergedReplacements = replacements.merging(
            memoryManager.acceptedReplacementPairs()
        ) { user, _ in user }
        let personalContext = PromptContextManager.shared.personalContext.details
        let recentDictations = recentDictationsProvider()

        // Long transcripts overwhelm small-model attention: past ~2k chars the
        // model either under-cleans or starts summarizing (benchmarked on real
        // history against Qwen 3.5 4B/9B, 2026-07-02). Sentence-boundary chunks
        // restore medium-length quality with zero content loss.
        let chunks = Self.splitIntoChunks(transcript)
        let chunkDuration = duration.map { $0 / Double(chunks.count) }
        if chunks.count > 1 {
            SapoLog.ai.info(
                "AI polish chunked chars=\(transcript.count, privacy: .public) chunks=\(chunks.count, privacy: .public)"
            )
        }

        // Replacement values are canonical spellings too ("buen mouse" ->
        // "BuenMouse"): once the deterministic correction pass has written
        // them into the transcript, a translation must not undo them, so
        // they anchor the fidelity guard alongside the keyterms.
        let vocabularyTerms = keyterms + Array(mergedReplacements.values)

        // Chunks 2+ see the raw tail of their predecessor: the tail comes from
        // the raw text (not the polished result), so hosted chunks still run
        // in parallel while keeping topic and sentence continuity at seams.
        func polishOne(_ index: Int, _ chunk: String) async -> ChunkOutcome {
            await polishChunk(
                chunk,
                previousChunkTail: index > 0
                    ? String(chunks[index - 1].suffix(Self.previousChunkTailCharacters)) : "",
                chunkDuration: chunkDuration,
                configuration: configuration,
                personalContext: personalContext,
                outputLanguage: outputLanguage,
                keyterms: keyterms,
                mergedReplacements: mergedReplacements,
                recentDictations: recentDictations,
                vocabularyTerms: vocabularyTerms
            )
        }

        var outcomes: [ChunkOutcome] = []
        if configuration.usesLocalTimeoutBudget || chunks.count == 1 {
            // Local endpoints serve one request at a time (single GPU, shared
            // prefix cache), so chunks run sequentially.
            for (index, chunk) in chunks.enumerated() {
                guard !Task.isCancelled else {
                    outcomes.append(
                        ChunkOutcome(
                            text: chunk, applied: false, blocked: false,
                            failureDetail: "polish cancelled", model: nil
                        )
                    )
                    continue
                }
                outcomes.append(await polishOne(index, chunk))
            }
        } else {
            // Hosted endpoints handle concurrent requests fine; running the
            // chunks together collapses the latency of a long dictation from
            // sum(chunks) to roughly max(chunk).
            outcomes = await withTaskGroup(of: (Int, ChunkOutcome).self) { group in
                for (index, chunk) in chunks.enumerated() {
                    group.addTask {
                        (index, await polishOne(index, chunk))
                    }
                }
                var byIndex = [ChunkOutcome?](repeating: nil, count: chunks.count)
                for await (index, outcome) in group {
                    byIndex[index] = outcome
                }
                return byIndex.enumerated().map { indexed in
                    indexed.element
                        ?? ChunkOutcome(
                            text: chunks[indexed.offset], applied: false, blocked: false,
                            failureDetail: "polish cancelled", model: nil
                        )
                }
            }
        }

        let anyApplied = outcomes.contains(where: \.applied)
        let model = outcomes.compactMap(\.model).last ?? configuration.modelIdentifier

        if anyApplied {
            let finalText = outcomes.map(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let salvagedCount = outcomes.filter { !$0.applied }.count
            if salvagedCount > 0 {
                SapoLog.ai.warning(
                    "AI polish salvaged chunks raw=\(salvagedCount, privacy: .public)/\(outcomes.count, privacy: .public)"
                )
            }
            return finish(
                finalText: finalText,
                status: .applied,
                model: model,
                mode: "automatic",
                error: salvagedCount > 0 ? "\(salvagedCount)/\(outcomes.count) chunks kept raw" : nil
            )
        }

        if outcomes.contains(where: \.blocked) {
            return finish(
                finalText: transcript,
                status: .rejectedFidelity,
                model: model,
                mode: "automatic",
                error: "AI polish answered or performed the transcript instead of polishing it"
            )
        }

        return finish(
            finalText: transcript,
            status: .failed,
            model: model,
            mode: "automatic",
            error: outcomes.compactMap(\.failureDetail).first ?? "AI polish failed"
        )
    }

    /// Polishes one chunk inside its own budget. Never throws: any failure
    /// (timeout, provider error, blocked output, empty output) falls back to
    /// the chunk's raw text so sibling chunks keep their polish.
    private func polishChunk(
        _ chunk: String,
        previousChunkTail: String,
        chunkDuration: TimeInterval?,
        configuration: PolishProviderConfiguration,
        personalContext: String,
        outputLanguage: TranscriptPolishOutputLanguage,
        keyterms: [String],
        mergedReplacements: [String: String],
        recentDictations: [String],
        vocabularyTerms: [String]
    ) async -> ChunkOutcome {
        let budget = Self.polishTimeout(
            forCharacterCount: chunk.count,
            duration: chunkDuration,
            configuration: configuration
        )
        // Generous output cap: roughly 2x the tokens the chunk itself needs.
        // Its real job is making finish_reason=="length" detectable instead of
        // shipping a silently truncated polish.
        let maxTokens = max(512, chunk.count * 2 / 3)

        do {
            let guarded = try await withTimeout(seconds: budget) {
                let messages = TranscriptPolishPromptBuilder.makeMessages(
                    rawText: chunk,
                    personalContext: personalContext,
                    outputLanguage: outputLanguage,
                    keyterms: keyterms,
                    replacements: mergedReplacements,
                    recentDictations: recentDictations,
                    previousChunkTail: previousChunkTail
                )
                return try await self.polishWithHardGuardRetries(
                    messages: messages,
                    rawText: chunk,
                    vocabularyTerms: vocabularyTerms,
                    outputLanguage: outputLanguage,
                    timeout: TimeInterval(budget),
                    maxTokens: maxTokens
                )
            }
            if guarded.blockedInstructionResponse {
                return ChunkOutcome(
                    text: chunk, applied: false, blocked: true,
                    failureDetail: nil, model: guarded.response.modelIdentifier
                )
            }
            guard !guarded.cleanedText.isEmpty else {
                return ChunkOutcome(
                    text: chunk, applied: false, blocked: false,
                    failureDetail: "empty polished text", model: guarded.response.modelIdentifier
                )
            }
            return ChunkOutcome(
                text: guarded.cleanedText, applied: true, blocked: false,
                failureDetail: nil, model: guarded.response.modelIdentifier
            )
        } catch is CancellationError where !Task.isCancelled {
            return ChunkOutcome(
                text: chunk, applied: false, blocked: false,
                failureDetail: "chunk timed out after \(budget)s", model: nil
            )
        } catch is CancellationError {
            return ChunkOutcome(
                text: chunk, applied: false, blocked: false,
                failureDetail: "polish cancelled", model: nil
            )
        } catch {
            return ChunkOutcome(
                text: chunk, applied: false, blocked: false,
                failureDetail: error.localizedDescription, model: nil
            )
        }
    }

    // MARK: - Chunking

    /// Cleaning quality decays past ~2k characters on small models; above this
    /// the transcript is split at sentence boundaries and each chunk is
    /// polished as its own transcript.
    static let chunkThresholdCharacters = 2_200
    /// Target size per chunk once splitting applies.
    static let chunkTargetCharacters = 1_600
    /// A tail chunk shorter than this polishes badly alone (no surrounding
    /// context), so it merges back into its neighbor.
    static let chunkTailMergeCharacters = 300
    /// Raw tail of the previous chunk passed as continuity context to chunks
    /// 2+ (benched at 250 chars against gpt-5.4-nano, 2026-07-04).
    static let previousChunkTailCharacters = 250

    /// Splits at sentence enders (. ! ? …) that close a word — a period inside
    /// "24.7", "10.000", ".env", or "CLAUDE.md" is not a boundary — grouping
    /// complete sentences up to the target size. Runs without usable enders
    /// (some engines emit no punctuation) fall back to whitespace splits, so a
    /// long transcript still chunks instead of reaching the model whole and
    /// getting summarized (benchmarked on real history, 2026-07-02).
    static func splitIntoChunks(_ text: String) -> [String] {
        guard text.count > chunkThresholdCharacters else { return [text] }

        var runs: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            let nextIndex = text.index(after: index)
            if ".!?…".contains(character) {
                let next = nextIndex < text.endIndex ? text[nextIndex] : " "
                if next.isWhitespace {
                    runs.append(current)
                    current = ""
                }
            }
            index = nextIndex
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runs.append(current)
        }

        var sentences: [String] = []
        for run in runs {
            guard run.count > chunkTargetCharacters else {
                sentences.append(run)
                continue
            }
            var piece = ""
            for word in run.split(separator: " ", omittingEmptySubsequences: false) {
                if !piece.isEmpty, piece.count + 1 + word.count > chunkTargetCharacters {
                    sentences.append(piece + " ")
                    piece = String(word)
                } else {
                    piece = piece.isEmpty ? String(word) : "\(piece) \(word)"
                }
            }
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(piece)
            }
        }

        var chunks: [String] = []
        var chunk = ""
        for sentence in sentences {
            if !chunk.isEmpty, chunk.count + sentence.count > chunkTargetCharacters {
                chunks.append(chunk.trimmingCharacters(in: .whitespacesAndNewlines))
                chunk = sentence
            } else {
                chunk += sentence
            }
        }
        let last = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            chunks.append(last)
        }
        if chunks.count >= 2,
            let tail = chunks.last, tail.count < chunkTailMergeCharacters,
            chunks[chunks.count - 2].count + tail.count <= chunkThresholdCharacters
        {
            chunks.removeLast()
            chunks[chunks.count - 1] += " \(tail)"
        }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Hard-token fidelity is a regeneration hint, not a raw-text fallback. If
    /// the model still misses a protected token after the retry budget, the last
    /// AI output ships because the user explicitly opted into AI polish.
    private func polishWithHardGuardRetries(
        messages: TranscriptPolishMessages,
        rawText: String,
        vocabularyTerms: [String],
        outputLanguage: TranscriptPolishOutputLanguage,
        timeout: TimeInterval,
        maxTokens: Int
    ) async throws -> GuardedPolishResponse {
        var attemptMessages = messages
        var lastInstructionRejected: GuardedPolishResponse?
        var attempt = 1

        while true {
            let response = try await polishVerifyingTranslation(
                messages: attemptMessages,
                rawText: rawText,
                outputLanguage: outputLanguage,
                timeout: timeout,
                maxTokens: maxTokens
            )
            let cleaned = PolishOutputSanitizer.clean(response.text, rawText: rawText)
            let guarded = GuardedPolishResponse(
                response: response,
                cleanedText: cleaned,
                blockedInstructionResponse: false
            )
            let fidelityVerdict = PolishFidelityGuard.evaluate(
                raw: rawText,
                polished: cleaned,
                vocabularyTerms: vocabularyTerms,
                translationExpected: outputLanguage.requiresTranslation
            )
            let instructionVerdict = PolishInstructionResponseGuard.evaluate(
                raw: rawText,
                polished: cleaned,
                translationExpected: outputLanguage.requiresTranslation
            )
            let contentDiffVerdict = PolishContentDiffGuard.evaluate(
                raw: rawText,
                polished: cleaned,
                translationExpected: outputLanguage.requiresTranslation
            )

            guard
                !fidelityVerdict.isAcceptable || !instructionVerdict.isAcceptable
                    || !contentDiffVerdict.isAcceptable
            else {
                if attempt > 1 {
                    SapoLog.ai.info("AI polish hard guard recovered attempt=\(attempt, privacy: .public)")
                }
                return guarded
            }

            if !instructionVerdict.isAcceptable {
                lastInstructionRejected = guarded
            }
            SapoLog.ai.warning(
                "AI polish hard guard retry attempt=\(attempt, privacy: .public) \(fidelityVerdict.diagnosticSummary, privacy: .public) \(instructionVerdict.diagnosticSummary, privacy: .public) \(contentDiffVerdict.diagnosticSummary, privacy: .public)"
            )

            if attempt >= Self.maximumFidelityAttempts {
                if let lastInstructionRejected {
                    SapoLog.ai.warning("AI polish rejected after instruction-response guard retries")
                    return GuardedPolishResponse(
                        response: lastInstructionRejected.response,
                        cleanedText: lastInstructionRejected.cleanedText,
                        blockedInstructionResponse: true
                    )
                }
                SapoLog.ai.warning("AI polish shipping last output after hard guard retry budget")
                return guarded
            }

            attempt += 1
            let instruction =
                instructionVerdict.retryInstruction ?? fidelityVerdict.retryInstruction
                ?? contentDiffVerdict.retryInstruction ?? """
                    A previous polish attempt changed protected tokens. Regenerate the full polished text from the original transcript and preserve URLs, emails, vocabulary terms, and identifiers exactly. Return ONLY the final polished transcript.
                    """
            attemptMessages = TranscriptPolishMessages(
                system: messages.system + "\n\n\(instruction)",
                user: messages.user
            )
        }
    }

    /// Runs the polish call and, when an explicit output language is set,
    /// verifies with NLLanguageRecognizer that the model actually translated.
    /// Long transcripts make small models ignore the language instruction, so
    /// one corrective retry runs inside the same timeout budget; if the retry
    /// itself fails, the first (untranslated but cleaned) attempt ships.
    private func polishVerifyingTranslation(
        messages: TranscriptPolishMessages,
        rawText: String,
        outputLanguage: TranscriptPolishOutputLanguage,
        timeout: TimeInterval,
        maxTokens: Int
    ) async throws -> PolishResponse {
        let first = try await polisher.polish(
            system: messages.system, user: messages.user, timeout: timeout, maxTokens: maxTokens
        )
        let firstCleaned = PolishOutputSanitizer.clean(first.text, rawText: rawText)

        // 12 chars is enough for NLLanguageRecognizer to call the dominant
        // language of a short greeting ("hola, ¿cómo estás?"); those short
        // dictations reach this path since the skip-gate bypass and were
        // exactly the ones shipping untranslated.
        guard
            let targetCode = outputLanguage.nlLanguageCode,
            let targetName = outputLanguage.englishName,
            firstCleaned.count >= 12
        else { return first }

        let detected = Self.dominantLanguageCode(of: firstCleaned)
        guard let detected, !detected.hasPrefix(targetCode) else {
            SapoLog.ai.info(
                "AI polish translation check target=\(targetCode, privacy: .public) detected=\(detected ?? "unknown", privacy: .public) result=ok"
            )
            return first
        }

        SapoLog.ai.warning(
            "AI polish translation missed target=\(targetCode, privacy: .public) detected=\(detected, privacy: .public) chars=\(firstCleaned.count, privacy: .public) action=retry"
        )

        let retrySystem =
            messages.system + """


                IMPORTANT: A previous attempt failed because it kept the transcript's original language. The final text MUST be written entirely in \(targetName). Translate everything.
                """

        do {
            let second = try await polisher.polish(
                system: retrySystem, user: messages.user, timeout: timeout, maxTokens: maxTokens
            )
            let secondCleaned = PolishOutputSanitizer.clean(second.text, rawText: rawText)
            let retryDetected = Self.dominantLanguageCode(of: secondCleaned) ?? "unknown"
            SapoLog.ai.info(
                "AI polish translation retry target=\(targetCode, privacy: .public) detected=\(retryDetected, privacy: .public) result=\(retryDetected.hasPrefix(targetCode) ? "ok" : "still-missed", privacy: .public)"
            )
            return retryDetected.hasPrefix(targetCode) ? second : first
        } catch {
            SapoLog.ai.warning(
                "AI polish translation retry failed; keeping first attempt detail=\(error.localizedDescription, privacy: .public)"
            )
            return first
        }
    }

    private static func dominantLanguageCode(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Output language as configured right now (Settings/menu-bar selection).
    static func configuredOutputLanguage(defaults: UserDefaults = .standard) -> TranscriptPolishOutputLanguage {
        let storedValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue
        return TranscriptPolishOutputLanguage(rawValue: storedValue) ?? .sameAsInput
    }

    /// Polish runs for every non-empty dictation when enabled and configured —
    /// no silent duration/length gates (they read as "the AI didn't work";
    /// see brain/lessons/sapowhisper-skip-gates-vs-explicit-output-language).
    /// Mirrors the exact gating of `process()` so the overlay countdown never
    /// promises a polish that will be skipped (or vice versa).
    func willAttemptPolish(rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled) else { return false }
        guard !PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults) else { return false }
        return PolishProviderConfiguration.current() != nil
    }

    private func makeResult(
        rawText: String,
        finalText: String,
        status: TranscriptAIStatus,
        model: String? = nil,
        mode: String? = nil,
        error: String? = nil,
        startedAt: CFAbsoluteTime
    ) -> TranscriptAIResult {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        return TranscriptAIResult(
            rawText: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            finalText: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            model: model,
            mode: mode,
            error: error,
            elapsedMs: elapsedMs
        )
    }

    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw CancellationError()
            }

            guard let value = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return value
        }
    }
}
