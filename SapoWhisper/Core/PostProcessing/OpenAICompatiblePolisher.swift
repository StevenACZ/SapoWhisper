//
//  OpenAICompatiblePolisher.swift
//  SapoWhisper
//

import Foundation
import os

struct PolishResponse: Sendable {
    let text: String
    /// Endpoint-qualified model id, e.g. `openrouter/openai/gpt-5.4-nano`.
    let modelIdentifier: String
}

enum PolishProviderError: LocalizedError {
    case notConfigured
    case emptyResponse(finishReason: String?)
    case httpError(statusCode: Int, endpoint: PolishEndpoint, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ai.provider.error_not_configured".localized
        case .emptyResponse:
            return "ai.provider.error_empty".localized
        case .httpError(let statusCode, let endpoint, let message):
            let friendlyMessage = Self.friendlyHTTPMessage(
                statusCode: statusCode,
                endpoint: endpoint,
                message: message
            )
            return "ai.provider.error_http".localized(String(statusCode), friendlyMessage)
        }
    }

    private static func friendlyHTTPMessage(
        statusCode: Int,
        endpoint: PolishEndpoint,
        message: String
    ) -> String {
        let lowercasedMessage = message.lowercased()

        if statusCode == 401 || statusCode == 403 || lowercasedMessage.contains("api key")
            || lowercasedMessage.contains("unauthorized") || lowercasedMessage.contains("invalid_api_key")
        {
            switch endpoint {
            case .openAI:
                return "ai.provider.error_auth_openai".localized
            case .openRouter:
                return "ai.provider.error_auth_openrouter".localized
            case .localServer, .custom:
                return "ai.provider.error_auth_local".localized(endpoint.displayName)
            case .groq:
                return "ai.provider.error_auth_generic".localized(endpoint.displayName)
            }
        }

        if statusCode == 404 || lowercasedMessage.contains("model") || lowercasedMessage.contains("endpoint") {
            return "ai.provider.error_model_or_endpoint".localized(endpoint.displayName)
        }

        if statusCode == 429 || lowercasedMessage.contains("rate") || lowercasedMessage.contains("quota")
            || lowercasedMessage.contains("credit")
        {
            return "ai.provider.error_rate_limited".localized(endpoint.displayName)
        }

        if (500...599).contains(statusCode) {
            return "ai.provider.error_server".localized(endpoint.displayName)
        }

        return "ai.provider.error_check_settings".localized(endpoint.displayName)
    }

    static func connectionTestMessage(for error: Error, endpoint: PolishEndpoint) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut:
                return "ai.provider.error_network_timeout".localized(endpoint.displayName)
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                return endpoint.usesEditableBaseURL
                    ? "ai.provider.error_network_local".localized(endpoint.displayName)
                    : "ai.provider.error_network_hosted".localized(endpoint.displayName)
            default:
                break
            }
        }

        return error.localizedDescription
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
        PolishProviderConfiguration.hasUsableConfiguration()
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
            throw PolishProviderError.httpError(
                statusCode: http.statusCode,
                endpoint: configuration.endpoint,
                message: message
            )
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
        let raw: String
        if let envelope = try? JSONDecoder().decode(ChatCompletionsErrorEnvelope.self, from: data) {
            raw = envelope.error.message
        } else {
            raw = String(data: data, encoding: .utf8) ?? "Unknown provider error"
        }
        // Redact before this string reaches the unified log (.public) and the
        // Settings test UI: a provider error body can echo a key or bearer token.
        return TranscriptionFailure.redactedLogSnippet(from: raw)
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
