//
//  TranscriptPostProcessor.swift
//  SapoWhisper
//

import Foundation
import os

final class TranscriptPostProcessor {
    /// L10: hard cap for one polish round-trip. The overlay countdown renders
    /// this same value, so keep them in sync by construction.
    static let polishTimeoutSeconds: UInt64 = 5

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
            let response = try await withTimeout(seconds: Self.polishTimeoutSeconds) {
                try await self.polisher.polish(system: messages.system, user: messages.user)
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

            let verdict = PolishFidelityGuard.evaluate(raw: trimmed, polished: cleaned, vocabularyTerms: keyterms)
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

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping () async throws -> T
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
