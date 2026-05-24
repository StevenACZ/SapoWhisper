//
//  GeminiTranscriptPolisher.swift
//  SapoWhisper
//

import Foundation

struct GeminiPolishResponse {
    let text: String
    let model: String
}

final class GeminiTranscriptPolisher {
    private let client: VertexGenerateContentClient
    private let models = [
        GoogleCloudConfig.vertexGeminiModel,
        GoogleCloudConfig.vertexGeminiPreviewModel,
    ]

    init(client: VertexGenerateContentClient = VertexGenerateContentClient()) {
        self.client = client
    }

    func polish(prompt: String) async throws -> GeminiPolishResponse {
        var lastError: Error?
        var uniqueModels: [String] = []
        for model in models where !uniqueModels.contains(model) {
            uniqueModels.append(model)
        }

        for model in uniqueModels {
            do {
                let text = try await polish(prompt: prompt, model: model)
                return GeminiPolishResponse(text: text, model: model)
            } catch let error as VertexGenerateContentError {
                if case .httpError(let statusCode, _) = error, statusCode == 404 {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? VertexGenerateContentError.emptyResponse
    }

    private func polish(prompt: String, model: String) async throws -> String {
        let response = try await client.generateContent(
            model: model,
            parts: [["text": prompt]],
            generationConfig: [
                "temperature": 0.2,
                "topP": 0.8,
                "candidateCount": 1,
                "maxOutputTokens": 2048,
                "responseMimeType": "text/plain",
            ],
            labels: [
                "app": "sapowhisper",
                "feature": "ai-polish",
            ],
            timeout: 8
        )
        return response.text
    }
}
