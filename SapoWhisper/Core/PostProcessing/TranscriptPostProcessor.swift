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

    /// L10: hard cap for the whole polish step (including the one translation
    /// retry). Hosted providers keep the snappy 5s-20s budget; local/LAN
    /// models get a larger budget because first-token latency and small-model
    /// reasoning can be much slower. The overlay countdown receives this same
    /// value via the polishing overlay state, so they stay in sync by
    /// construction.
    static func polishTimeout(forCharacterCount count: Int) -> UInt64 {
        polishTimeout(forCharacterCount: count, duration: nil, usesLocalBudget: false)
    }

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
        duration: TimeInterval? = nil,
        force: Bool = false
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

        let modeValue = defaults.string(forKey: Constants.StorageKeys.aiPolishMode) ?? TranscriptPolishMode.automatic.rawValue
        let promptProfile = PromptContextManager.shared.promptProfile(for: modeValue)
        let outputLanguage = Self.configuredOutputLanguage(defaults: defaults)

        // An explicit output language is a hard user requirement: skipping
        // polish for a short dictation would silently ship the untranslated
        // transcript, so the duration/length gates only apply to same-as-input.
        let skipGatesApply = Self.skipGatesApply(force: force, outputLanguage: outputLanguage)

        guard !skipGatesApply || !Self.shouldSkipPolishForDuration(duration, defaults: defaults) else {
            return finish(
                finalText: transcript,
                status: .skippedDuration,
                mode: promptProfile.id
            )
        }

        guard !skipGatesApply || !Self.shouldSkipPolish(transcript) else {
            return finish(
                finalText: transcript,
                status: .skippedShort,
                mode: promptProfile.id
            )
        }

        let memoryContext = memoryManager.contextPacket(
            rawText: trimmed,
            correctedText: transcript,
            keyterms: keyterms,
            replacements: replacements
        )
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: transcript,
            promptProfile: promptProfile,
            personalContext: PromptContextManager.shared.personalContext.details,
            outputLanguage: outputLanguage,
            keyterms: keyterms,
            replacements: replacements,
            memoryContext: memoryContext,
            recentDictations: recentDictationsProvider()
        )

        let timeoutSeconds = Self.polishTimeout(
            forCharacterCount: transcript.count,
            duration: duration,
            configuration: configuration
        )

        do {
            // Replacement values are canonical spellings too ("buen mouse" ->
            // "BuenMouse"): once the deterministic correction pass has written
            // them into the transcript, a translation must not undo them, so
            // they anchor the fidelity guard alongside the keyterms.
            let guardedResponse = try await withTimeout(seconds: timeoutSeconds) {
                try await self.polishWithHardGuardRetries(
                    messages: messages,
                    rawText: transcript,
                    vocabularyTerms: keyterms + Array(replacements.values),
                    outputLanguage: outputLanguage,
                    timeout: TimeInterval(timeoutSeconds)
                )
            }
            guard !guardedResponse.cleanedText.isEmpty else {
                return finish(
                    finalText: transcript,
                    status: .failed,
                    model: guardedResponse.response.modelIdentifier,
                    mode: promptProfile.id,
                    error: "empty polished text"
                )
            }
            guard !guardedResponse.blockedInstructionResponse else {
                return finish(
                    finalText: transcript,
                    status: .rejectedFidelity,
                    model: guardedResponse.response.modelIdentifier,
                    mode: promptProfile.id,
                    error: "AI polish answered or performed the transcript instead of polishing it"
                )
            }

            return finish(
                finalText: guardedResponse.cleanedText,
                status: .applied,
                model: guardedResponse.response.modelIdentifier,
                mode: promptProfile.id
            )
        } catch is CancellationError {
            return finish(
                finalText: transcript,
                status: .failed,
                model: configuration.modelIdentifier,
                mode: promptProfile.id,
                error: "AI polish timed out after \(timeoutSeconds)s"
            )
        } catch {
            return finish(
                finalText: transcript,
                status: .failed,
                model: configuration.modelIdentifier,
                mode: promptProfile.id,
                error: error.localizedDescription
            )
        }
    }

    /// Clipboard-edit sessions: apply a spoken instruction to copied text.
    /// The output legitimately differs from both inputs, so the fidelity and
    /// instruction-response guards do not run — only the sanitizer does.
    /// On any failure the source text ships unchanged (with the error recorded)
    /// so the flow never blocks or pastes something unrelated.
    func processEdit(
        sourceText: String,
        instruction: String,
        duration: TimeInterval? = nil
    ) async -> TranscriptAIResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        func finish(
            finalText: String,
            status: TranscriptAIStatus,
            model: String? = nil,
            error: String? = nil
        ) -> TranscriptAIResult {
            makeResult(
                rawText: trimmedInstruction,
                finalText: finalText,
                status: status,
                model: model,
                mode: "clipboard_edit",
                error: error,
                startedAt: startedAt
            )
        }

        guard !trimmedSource.isEmpty, !trimmedInstruction.isEmpty else {
            return finish(finalText: trimmedSource, status: .none)
        }

        let enabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled, let configuration = PolishProviderConfiguration.current() else {
            return finish(finalText: trimmedSource, status: .failed, error: "clipboard edit requires a configured AI provider")
        }

        let messages = ClipboardEditPromptBuilder.makeMessages(
            sourceText: trimmedSource,
            instruction: trimmedInstruction
        )
        let timeoutSeconds = Self.polishTimeout(
            forCharacterCount: trimmedSource.count + trimmedInstruction.count,
            duration: duration,
            configuration: configuration
        )

        do {
            let response = try await withTimeout(seconds: timeoutSeconds) {
                try await self.polisher.polish(
                    system: messages.system,
                    user: messages.user,
                    timeout: TimeInterval(timeoutSeconds)
                )
            }
            let cleaned = PolishOutputSanitizer.clean(response.text, rawText: trimmedSource)
            guard !cleaned.isEmpty else {
                return finish(
                    finalText: trimmedSource,
                    status: .failed,
                    model: response.modelIdentifier,
                    error: "empty edited text"
                )
            }
            return finish(finalText: cleaned, status: .applied, model: response.modelIdentifier)
        } catch is CancellationError {
            return finish(
                finalText: trimmedSource,
                status: .failed,
                model: configuration.modelIdentifier,
                error: "clipboard edit timed out after \(timeoutSeconds)s"
            )
        } catch {
            return finish(
                finalText: trimmedSource,
                status: .failed,
                model: configuration.modelIdentifier,
                error: error.localizedDescription
            )
        }
    }

    /// Hard-token fidelity is a regeneration hint, not a raw-text fallback. If
    /// the model still misses a protected token after the retry budget, the last
    /// AI output ships because the user explicitly opted into AI polish.
    private func polishWithHardGuardRetries(
        messages: TranscriptPolishMessages,
        rawText: String,
        vocabularyTerms: [String],
        outputLanguage: TranscriptPolishOutputLanguage,
        timeout: TimeInterval
    ) async throws -> GuardedPolishResponse {
        var attemptMessages = messages
        var lastRejected: GuardedPolishResponse?
        var lastInstructionRejected: GuardedPolishResponse?

        for attempt in 1...Self.maximumFidelityAttempts {
            let response = try await polishVerifyingTranslation(
                messages: attemptMessages,
                rawText: rawText,
                outputLanguage: outputLanguage,
                timeout: timeout
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
                translationExpected: outputLanguage.requiresTranslation,
                targetIsDenseScript: outputLanguage.usesDenseScript
            )
            let instructionVerdict = PolishInstructionResponseGuard.evaluate(
                raw: rawText,
                polished: cleaned,
                translationExpected: outputLanguage.requiresTranslation
            )

            guard !fidelityVerdict.isAcceptable || !instructionVerdict.isAcceptable else {
                if attempt > 1 {
                    SapoLog.ai.info("AI polish hard guard recovered attempt=\(attempt, privacy: .public)")
                }
                return guarded
            }

            lastRejected = guarded
            if !instructionVerdict.isAcceptable {
                lastInstructionRejected = guarded
            }
            SapoLog.ai.warning(
                "AI polish hard guard retry attempt=\(attempt, privacy: .public) \(fidelityVerdict.diagnosticSummary, privacy: .public) \(instructionVerdict.diagnosticSummary, privacy: .public)"
            )
            guard attempt < Self.maximumFidelityAttempts else { break }

            let instruction =
                instructionVerdict.retryInstruction ?? fidelityVerdict.retryInstruction ?? """
                    A previous polish attempt changed protected tokens. Regenerate the full polished text from the original transcript and preserve URLs, emails, vocabulary terms, and identifiers exactly. Return ONLY the final polished transcript.
                    """
            attemptMessages = TranscriptPolishMessages(
                system: messages.system + "\n\n\(instruction)",
                user: messages.user
            )
        }

        if let lastInstructionRejected {
            SapoLog.ai.warning("AI polish rejected after instruction-response guard retries")
            return GuardedPolishResponse(
                response: lastInstructionRejected.response,
                cleanedText: lastInstructionRejected.cleanedText,
                blockedInstructionResponse: true
            )
        }

        if let lastRejected {
            SapoLog.ai.warning("AI polish shipping last output after hard guard retry budget")
            return lastRejected
        }

        let response = try await polishVerifyingTranslation(
            messages: messages,
            rawText: rawText,
            outputLanguage: outputLanguage,
            timeout: timeout
        )
        return GuardedPolishResponse(
            response: response,
            cleanedText: PolishOutputSanitizer.clean(response.text, rawText: rawText),
            blockedInstructionResponse: false
        )
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
        timeout: TimeInterval
    ) async throws -> PolishResponse {
        let first = try await polisher.polish(system: messages.system, user: messages.user, timeout: timeout)
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
            let second = try await polisher.polish(system: retrySystem, user: messages.user, timeout: timeout)
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

    /// The duration/length skip gates never apply when the polish was forced
    /// explicitly or when an explicit output language requires a translation
    /// pass — a translation the user configured must never be skipped.
    static func skipGatesApply(force: Bool, outputLanguage: TranscriptPolishOutputLanguage) -> Bool {
        !force && !outputLanguage.requiresTranslation
    }

    /// Output language as configured right now (Settings/menu-bar selection),
    /// resolved through the same profile-aware path `process()` uses.
    static func configuredOutputLanguage(defaults: UserDefaults = .standard) -> TranscriptPolishOutputLanguage {
        let modeValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishMode)
            ?? TranscriptPolishMode.automatic.rawValue
        let promptProfile = PromptContextManager.shared.promptProfile(for: modeValue)
        let storedValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue
        let selected = TranscriptPolishOutputLanguage(rawValue: storedValue) ?? .sameAsInput
        return PromptContextManager.effectiveOutputLanguage(selected: selected, for: promptProfile)
    }

    static func shouldSkipPolish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let words =
            trimmed
            .split { $0.isWhitespace || $0.isNewline }
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }

        if trimmed.count < 35 { return true }
        if words.count <= 3 { return true }

        let normalized = words.joined(separator: " ")
        let simpleUtterances: Set<String> = [
            "hola", "hello", "hi", "ok", "okay", "gracias", "thanks", "si", "sí", "dale", "listo", "ya", "no",
        ]
        return simpleUtterances.contains(normalized)
    }

    static func shouldSkipPolishForDuration(_ duration: TimeInterval?, defaults: UserDefaults = .standard) -> Bool {
        let value =
            defaults.string(forKey: Constants.StorageKeys.aiPolishMinimumDuration)
            ?? TranscriptPolishMinimumDuration.defaultPolicy.rawValue
        let policy = TranscriptPolishMinimumDuration(rawValue: value) ?? .defaultPolicy

        guard let minimumSeconds = policy.minimumSeconds, let duration else {
            return false
        }

        return duration < minimumSeconds
    }

    func willAttemptPolish(rawText: String, duration: TimeInterval? = nil, force: Bool = false) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let recognitionCorrectedText =
            vocabularyManager
            .applyingRecognitionCorrections(to: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = recognitionCorrectedText.isEmpty ? trimmed : recognitionCorrectedText

        let enabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard !PolishProviderConfiguration.hostedEndpointIsPausedOffline() else { return false }
        guard enabled, polisher.isConfigured else { return false }

        guard Self.skipGatesApply(force: force, outputLanguage: Self.configuredOutputLanguage()) else {
            return true
        }
        return !Self.shouldSkipPolishForDuration(duration) && !Self.shouldSkipPolish(transcript)
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
