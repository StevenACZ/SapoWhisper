//
//  VertexGenerateContentClient.swift
//  SapoWhisper
//

import Foundation

struct VertexGenerateContentResult {
    let text: String
    let model: String
    let usage: VertexUsageMetadata?
}

struct VertexUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
    let thoughtsTokenCount: Int?
}

enum VertexGenerateContentError: LocalizedError {
    case notConfigured
    case invalidURL
    case emptyResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Cloud credentials not configured"
        case .invalidURL:
            return "Invalid Vertex AI URL"
        case .emptyResponse:
            return "Gemini returned an empty response"
        case .httpError(let statusCode, let message):
            return "Gemini error (\(statusCode)): \(message)"
        }
    }
}

final class VertexGenerateContentClient {
    private let location: String

    init(location: String = GoogleCloudConfig.vertexLocation) {
        self.location = location
    }

    func generateContent(
        model: String,
        parts: [[String: Any]],
        generationConfig: [String: Any],
        labels: [String: String],
        timeout: TimeInterval
    ) async throws -> VertexGenerateContentResult {
        guard ServiceAccountManager.shared.isConfigured else {
            throw VertexGenerateContentError.notConfigured
        }

        let token = try await ServiceAccountManager.shared.getValidAccessToken()
        guard let projectID = ServiceAccountManager.shared.projectID else {
            throw VertexGenerateContentError.notConfigured
        }

        let escapedProject = projectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
        let host = vertexAIHost(for: location)
        let endpoint =
            "https://\(host)/v1/projects/\(escapedProject)/locations/\(location)/publishers/google/models/\(model):generateContent"

        guard let url = URL(string: endpoint) else {
            throw VertexGenerateContentError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(projectID, forHTTPHeaderField: "x-goog-user-project")

        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": parts,
                ]
            ],
            "generationConfig": generationConfig,
            "labels": labels,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VertexGenerateContentError.httpError(-1, "Invalid Vertex AI response")
        }

        guard http.statusCode == 200 else {
            let message = parseErrorMessage(from: data)
            throw VertexGenerateContentError.httpError(http.statusCode, message)
        }

        let responseBody = try JSONDecoder().decode(VertexGenerateContentResponse.self, from: data)
        let text =
            responseBody.candidates?
            .flatMap { $0.content?.parts ?? [] }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            throw VertexGenerateContentError.emptyResponse
        }

        return VertexGenerateContentResult(text: text, model: model, usage: responseBody.usageMetadata)
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
    let usageMetadata: VertexUsageMetadata?
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
