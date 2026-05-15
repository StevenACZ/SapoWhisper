//
//  GeminiAudioTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation
import os

final class GeminiAudioTranscriber: ObservableObject {
    @Published var isTranscribing = false

    private let client: VertexGenerateContentClient
    private let timeout: TimeInterval = 45

    init(client: VertexGenerateContentClient = VertexGenerateContentClient()) {
        self.client = client
    }

    var isConfigured: Bool {
        ServiceAccountManager.shared.isConfigured
    }

    func transcribe(audioURL: URL, language: String, model: GeminiAudioModel) async throws -> String {
        guard isConfigured else {
            throw VertexGenerateContentError.notConfigured
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        let audioData = try Data(contentsOf: audioURL)
        let estimatedSeconds = estimateDurationSeconds(audioBytes: audioData.count)
        let startedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.gemini.info(
            "Gemini audio transcription started model=\(model.rawValue, privacy: .public) bytes=\(audioData.count, privacy: .public) estimatedSec=\(estimatedSeconds, privacy: .public)"
        )

        let prompt = GeminiAudioTranscriptionPromptBuilder.makePrompt(
            language: language,
            personalContext: PromptContextManager.shared.makePersonalContextBlock(),
            keyterms: VocabularyManager.shared.keyterms,
            replacements: VocabularyManager.shared.replacements
        )

        let response = try await client.generateContent(
            model: model.rawValue,
            parts: [
                [
                    "inlineData": [
                        "mimeType": "audio/wav",
                        "data": audioData.base64EncodedString(),
                    ]
                ],
                ["text": prompt],
            ],
            generationConfig: [
                "temperature": 0.0,
                "topP": 0.8,
                "candidateCount": 1,
                "maxOutputTokens": 8192,
                "responseMimeType": "text/plain",
            ],
            labels: [
                "app": "sapowhisper",
                "feature": "gemini-audio",
            ],
            timeout: timeout
        )

        let transcript = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw VertexGenerateContentError.emptyResponse
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.gemini.info(
            "Gemini audio transcription finished model=\(response.model, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(transcript.count, privacy: .public) promptTokens=\(response.usage?.promptTokenCount ?? -1, privacy: .public) outputTokens=\(response.usage?.candidatesTokenCount ?? -1, privacy: .public) totalTokens=\(response.usage?.totalTokenCount ?? -1, privacy: .public)"
        )

        return transcript
    }

    private func estimateDurationSeconds(audioBytes: Int) -> Int {
        max(0, Int((Double(audioBytes) / (16_000.0 * 2.0)).rounded()))
    }
}
