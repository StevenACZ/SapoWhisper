//
//  TranscriptPostProcessor.swift
//  SapoWhisper
//

import Foundation
import NaturalLanguage
import os

final class TranscriptPostProcessor {
    /// L10: hard cap for the whole polish step (including the one translation
    /// retry). Short dictations keep the snappy 5s budget; long transcripts
    /// scale up so a real translation round-trip fits instead of dying in a
    /// CancellationError. The overlay countdown receives this same value via
    /// the polishing overlay state, so they stay in sync by construction.
    static func polishTimeout(forCharacterCount count: Int) -> UInt64 {
        let base: UInt64 = 5
        let extra = UInt64(max(0, count - 400) / 200)
        return min(base + extra, 20)
    }

    private let polisher: OpenAICompatiblePolisher

    init(polisher: OpenAICompatiblePolisher = OpenAICompatiblePolisher()) {
        self.polisher = polisher
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

        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled else {
            return makeResult(rawText: rawText, finalText: trimmed, status: .none, startedAt: startedAt)
        }

        guard !PolishProviderConfiguration.hostedEndpointIsPausedOffline(defaults: defaults) else {
            SapoLog.ai.info("AI polish skipped reason=offline-hosted-provider")
            return makeResult(rawText: rawText, finalText: trimmed, status: .none, startedAt: startedAt)
        }

        guard let configuration = PolishProviderConfiguration.current() else {
            // Enabled but no usable provider: dictation must never block on
            // polish, so the raw transcript ships untouched.
            SapoLog.ai.info("AI polish skipped reason=not-configured")
            return makeResult(rawText: rawText, finalText: trimmed, status: .none, startedAt: startedAt)
        }

        let modeValue = defaults.string(forKey: Constants.StorageKeys.aiPolishMode) ?? TranscriptPolishMode.automatic.rawValue
        let promptProfile = PromptContextManager.shared.promptProfile(for: modeValue)
        let outputLanguageValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue
        var outputLanguage = TranscriptPolishOutputLanguage(rawValue: outputLanguageValue) ?? .sameAsInput
        if promptProfile.forcesEnglish {
            outputLanguage = .english
        }

        guard force || !Self.shouldSkipPolishForDuration(duration, defaults: defaults) else {
            return makeResult(
                rawText: rawText,
                finalText: trimmed,
                status: .skippedDuration,
                mode: promptProfile.id,
                startedAt: startedAt
            )
        }

        guard force || !Self.shouldSkipPolish(trimmed) else {
            return makeResult(
                rawText: rawText,
                finalText: trimmed,
                status: .skippedShort,
                mode: promptProfile.id,
                startedAt: startedAt
            )
        }

        let keyterms = VocabularyManager.shared.keyterms
        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: trimmed,
            promptProfile: promptProfile,
            personalContext: PromptContextManager.shared.personalContext.details,
            outputLanguage: outputLanguage,
            keyterms: keyterms,
            replacements: VocabularyManager.shared.replacements
        )

        do {
            let timeoutSeconds = Self.polishTimeout(forCharacterCount: trimmed.count)
            let response = try await withTimeout(seconds: timeoutSeconds) {
                try await self.polishVerifyingTranslation(
                    messages: messages,
                    rawText: trimmed,
                    outputLanguage: outputLanguage,
                    timeout: TimeInterval(timeoutSeconds)
                )
            }
            let cleaned = PolishOutputSanitizer.clean(response.text, rawText: trimmed)
            guard !cleaned.isEmpty else {
                return makeResult(
                    rawText: rawText,
                    finalText: trimmed,
                    status: .failed,
                    model: response.modelIdentifier,
                    mode: promptProfile.id,
                    error: "empty polished text",
                    startedAt: startedAt
                )
            }

            let verdict = PolishFidelityGuard.evaluate(
                raw: trimmed,
                polished: cleaned,
                vocabularyTerms: keyterms,
                translationExpected: outputLanguage.requiresTranslation,
                targetIsDenseScript: outputLanguage.usesDenseScript
            )
            guard verdict.isAcceptable else {
                SapoLog.ai.warning(
                    "AI polish rejected by fidelity guard \(verdict.diagnosticSummary, privacy: .public)"
                )
                return makeResult(
                    rawText: rawText,
                    finalText: trimmed,
                    status: .rejectedFidelity,
                    model: response.modelIdentifier,
                    mode: promptProfile.id,
                    error: verdict.diagnosticSummary,
                    startedAt: startedAt
                )
            }

            return makeResult(
                rawText: rawText,
                finalText: cleaned,
                status: .applied,
                model: response.modelIdentifier,
                mode: promptProfile.id,
                startedAt: startedAt
            )
        } catch {
            return makeResult(
                rawText: rawText,
                finalText: trimmed,
                status: .failed,
                model: configuration.modelIdentifier,
                mode: promptProfile.id,
                error: error.localizedDescription,
                startedAt: startedAt
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
        timeout: TimeInterval
    ) async throws -> PolishResponse {
        let first = try await polisher.polish(system: messages.system, user: messages.user, timeout: timeout)
        let firstCleaned = PolishOutputSanitizer.clean(first.text, rawText: rawText)

        guard
            let targetCode = outputLanguage.nlLanguageCode,
            let targetName = outputLanguage.englishName,
            firstCleaned.count >= 20
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

        let enabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard !PolishProviderConfiguration.hostedEndpointIsPausedOffline() else { return false }
        guard enabled, polisher.isConfigured else { return false }

        return force || (!Self.shouldSkipPolishForDuration(duration) && !Self.shouldSkipPolish(trimmed))
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
