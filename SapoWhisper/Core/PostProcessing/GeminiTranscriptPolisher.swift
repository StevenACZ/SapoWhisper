//
//  GeminiTranscriptPolisher.swift
//  SapoWhisper
//

import Foundation

struct GeminiPolishResponse {
    let text: String
    let model: String
}

enum GeminiTranscriptPolisherError: LocalizedError {
    case notConfigured
    case emptyResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Cloud credentials not configured"
        case .emptyResponse:
            return "Gemini returned an empty response"
        case .httpError(let statusCode, let message):
            return "Gemini error (\(statusCode)): \(message)"
        }
    }
}

final class GeminiTranscriptPolisher {
    private let location = GoogleCloudConfig.vertexLocation
    private let models = [
        GoogleCloudConfig.vertexGeminiModel,
        GoogleCloudConfig.vertexGeminiPreviewModel,
    ]

    func polish(prompt: String) async throws -> GeminiPolishResponse {
        guard ServiceAccountManager.shared.isConfigured else {
            throw GeminiTranscriptPolisherError.notConfigured
        }

        var lastError: Error?
        var uniqueModels: [String] = []
        for model in models where !uniqueModels.contains(model) {
            uniqueModels.append(model)
        }

        for model in uniqueModels {
            do {
                let text = try await polish(prompt: prompt, model: model)
                return GeminiPolishResponse(text: text, model: model)
            } catch let error as GeminiTranscriptPolisherError {
                if case .httpError(let statusCode, _) = error, statusCode == 404 {
                    lastError = error
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }

        throw lastError ?? GeminiTranscriptPolisherError.emptyResponse
    }

    private func polish(prompt: String, model: String) async throws -> String {
        let token = try await ServiceAccountManager.shared.getValidAccessToken()
        guard let projectID = ServiceAccountManager.shared.projectID else {
            throw GeminiTranscriptPolisherError.notConfigured
        }

        let escapedProject = projectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
        let host = vertexAIHost(for: location)
        let endpoint =
            "https://\(host)/v1/projects/\(escapedProject)/locations/\(location)/publishers/google/models/\(model):generateContent"

        guard let url = URL(string: endpoint) else {
            throw GeminiTranscriptPolisherError.httpError(-1, "Invalid Vertex AI URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(projectID, forHTTPHeaderField: "x-goog-user-project")

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": prompt]],
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,
                "topP": 0.8,
                "candidateCount": 1,
                "maxOutputTokens": 2048,
                "responseMimeType": "text/plain",
            ],
            "labels": [
                "app": "sapowhisper",
                "feature": "ai-polish",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiTranscriptPolisherError.httpError(-1, "Invalid Vertex AI response")
        }

        guard http.statusCode == 200 else {
            let message = parseErrorMessage(from: data)
            throw GeminiTranscriptPolisherError.httpError(http.statusCode, message)
        }

        let responseBody = try JSONDecoder().decode(VertexGenerateContentResponse.self, from: data)
        let text =
            responseBody.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            throw GeminiTranscriptPolisherError.emptyResponse
        }

        return text
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(VertexErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown Vertex AI error"
    }

    private func vertexAIHost(for location: String) -> String {
        switch location {
        case "global", "us", "eu":
            return "aiplatform.googleapis.com"
        default:
            return "\(location)-aiplatform.googleapis.com"
        }
    }
}

private struct VertexGenerateContentResponse: Decodable {
    let candidates: [VertexCandidate]?
}

private struct VertexCandidate: Decodable {
    let content: VertexContent?
}

private struct VertexContent: Decodable {
    let parts: [VertexPart]?
}

private struct VertexPart: Decodable {
    let text: String?
}

private struct VertexErrorEnvelope: Decodable {
    let error: VertexErrorBody
}

private struct VertexErrorBody: Decodable {
    let message: String
}
