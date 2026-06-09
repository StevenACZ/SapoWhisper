//
//  OpenAICompatiblePolisher.swift
//  SapoWhisper
//

import Foundation
import os

struct PolishResponse {
    let text: String
    /// Endpoint-qualified model id, e.g. `openrouter/openai/gpt-5.4-nano`.
    let modelIdentifier: String
}

enum PolishProviderError: LocalizedError {
    case notConfigured
    case emptyResponse(finishReason: String?)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ai.provider.error_not_configured".localized
        case .emptyResponse:
            return "ai.provider.error_empty".localized
        case .httpError(let statusCode, let message):
            return "ai.provider.error_http".localized(String(statusCode), message)
        }
    }
}

/// Thin client for any `chat/completions`-compatible endpoint (OpenRouter,
/// OpenAI, Groq, Ollama, LM Studio). One request shape, no provider SDKs.
final class OpenAICompatiblePolisher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool {
        PolishProviderConfiguration.current() != nil
    }

    func polish(system: String, user: String, timeout: TimeInterval = 8) async throws -> PolishResponse {
        guard let configuration = PolishProviderConfiguration.current() else {
            throw PolishProviderError.notConfigured
        }
        return try await send(system: system, user: user, timeout: timeout, configuration: configuration)
    }

    /// Round-trips a canned sentence to validate endpoint + key + model in one
    /// click. Shared by the settings Test button and the Welcome flow.
    func runConnectionTest() async throws -> PolishResponse {
        guard let configuration = PolishProviderConfiguration.current() else {
            throw PolishProviderError.notConfigured
        }
        return try await send(
            system: "Return the user's sentence exactly as written, with no additions.",
            user: "SapoWhisper connection test.",
            timeout: 12,
            configuration: configuration
        )
    }

    private func send(
        system: String,
        user: String,
        timeout: TimeInterval,
        configuration: PolishProviderConfiguration,
        includeTemperature: Bool = true
    ) async throws -> PolishResponse {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let request = try makeRequest(
            system: system,
            user: user,
            timeout: timeout,
            configuration: configuration,
            includeTemperature: includeTemperature
        )

        let (data, http) = try await TransientRequestRetry.data(for: request, session: session, engine: "AIPolish")

        guard http.statusCode == 200 else {
            let message = Self.parseErrorMessage(from: data)
            // Reasoning-tier models on some providers reject sampling params;
            // retry once without temperature so "paste a key" still works.
            if http.statusCode == 400, includeTemperature, message.lowercased().contains("temperature") {
                SapoLog.ai.info("Polish provider rejected temperature — retrying without it")
                return try await send(
                    system: system,
                    user: user,
                    timeout: timeout,
                    configuration: configuration,
                    includeTemperature: false
                )
            }
            throw PolishProviderError.httpError(http.statusCode, message)
        }

        let body = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        let choice = body.choices?.first
        let text = (choice?.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finishReason = choice?.finishReason ?? "none"
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.ai.info(
            "Polish provider response endpoint=\(configuration.endpoint.rawValue, privacy: .public) finishReason=\(finishReason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(text.count, privacy: .public)"
        )

        guard !text.isEmpty else {
            throw PolishProviderError.emptyResponse(finishReason: choice?.finishReason)
        }

        return PolishResponse(text: text, modelIdentifier: configuration.modelIdentifier)
    }

    private func makeRequest(
        system: String,
        user: String,
        timeout: TimeInterval,
        configuration: PolishProviderConfiguration,
        includeTemperature: Bool
    ) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if configuration.endpoint == .openRouter {
            request.setValue("https://github.com/StevenACZ/SapoWhisper", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("SapoWhisper", forHTTPHeaderField: "X-Title")
        }

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if includeTemperature {
            body["temperature"] = 0.1
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseErrorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ChatCompletionsErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "Unknown provider error"
    }
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [ChatChoice]?
}

private struct ChatChoice: Decodable {
    let message: ChatMessage?
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct ChatMessage: Decodable {
    let content: String?
}

private struct ChatCompletionsErrorEnvelope: Decodable {
    let error: ChatCompletionsErrorBody
}

private struct ChatCompletionsErrorBody: Decodable {
    let message: String
}
