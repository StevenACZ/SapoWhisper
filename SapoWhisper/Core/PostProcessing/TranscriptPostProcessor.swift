//
//  TranscriptPostProcessor.swift
//  SapoWhisper
//

import Foundation

final class TranscriptPostProcessor {
    private let polisher: GeminiTranscriptPolisher

    init(polisher: GeminiTranscriptPolisher = GeminiTranscriptPolisher()) {
        self.polisher = polisher
    }

    func process(rawText: String, force: Bool = false) async -> TranscriptAIResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return makeResult(rawText: rawText, finalText: trimmed, status: .none, startedAt: startedAt)
        }

        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled || force else {
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

        guard force || !Self.shouldSkipPolish(trimmed) else {
            return makeResult(
                rawText: rawText,
                finalText: trimmed,
                status: .skippedShort,
                mode: promptProfile.id,
                startedAt: startedAt
            )
        }

        let prompt = TranscriptPolishPromptBuilder.makePrompt(
            rawText: trimmed,
            promptProfile: promptProfile,
            personalContext: PromptContextManager.shared.makePersonalContextBlock(),
            outputLanguage: outputLanguage,
            keyterms: VocabularyManager.shared.keyterms,
            replacements: VocabularyManager.shared.replacements
        )

        do {
            let response = try await withTimeout(seconds: 8) {
                try await self.polisher.polish(prompt: prompt)
            }
            let finalText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return makeResult(
                rawText: rawText,
                finalText: finalText.isEmpty ? trimmed : finalText,
                status: .applied,
                model: response.model,
                mode: promptProfile.id,
                startedAt: startedAt
            )
        } catch {
            return makeResult(
                rawText: rawText,
                finalText: trimmed,
                status: .failed,
                model: GoogleCloudConfig.vertexGeminiModel,
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

    func willAttemptPolish(rawText: String, force: Bool = false) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let enabled = UserDefaults.standard.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled || force else { return false }

        return force || !Self.shouldSkipPolish(trimmed)
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
