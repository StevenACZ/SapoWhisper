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
    case truncatedResponse
    case httpError(statusCode: Int, endpoint: PolishEndpoint, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ai.provider.error_not_configured".localized
        case .emptyResponse:
            return "ai.provider.error_empty".localized
        case .truncatedResponse:
            return "ai.provider.error_truncated".localized
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
///
/// On endpoints that support structured outputs the polish call uses a strict
/// JSON schema with a leading `filler_scan` field: forcing the model to
/// enumerate the fillers it found before writing `polished` measurably cuts
/// leftover fillers on long chunks (benched against gpt-5.4-nano on real
/// history, 2026-07-04) and removes the preamble/code-fence failure modes.
/// A rejected structured request falls back to the plain-text contract.
final class OpenAICompatiblePolisher {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool {
        PolishProviderConfiguration.hasUsableConfiguration()
    }

    /// Extra output budget for the `filler_scan` field and JSON overhead so
    /// structured mode never eats into the polished text's token budget.
    private static let structuredOutputTokenHeadroom = 192

    /// Extra output budget when reasoning is explicitly requested: reasoning
    /// tokens count against `max_tokens` on every provider, so a cap sized for
    /// the polished text alone would truncate the answer mid-thought.
    private static let reasoningTokenHeadroom = 4096

    private static let structuredScanNote = """


        Return a JSON object. First fill `filler_scan`: list every filler occurrence you found while scanning the whole transcript. Then fill `polished` with the final cleaned text — every filler you listed must be gone from it.
        """

    private static let structuredResponseFormat: [String: Any] = [
        "type": "json_schema",
        "json_schema": [
            "name": "polish",
            "strict": true,
            "schema": [
                "type": "object",
                "properties": [
                    "filler_scan": [
                        "type": "string",
                        "description":
                            "Comma-separated list of every filler occurrence you found in the transcript (e.g. 'eh x3, como se dice x2, digamos x1'). Scan the WHOLE transcript before writing the polished text. Count 'como se dice' every single time, including when it introduces a term ('eso es como se dice el happy path' → 'eso es el happy path') — it is always filler.",
                    ],
                    "polished": [
                        "type": "string",
                        "description": "The final cleaned text, and nothing else.",
                    ],
                ],
                "required": ["filler_scan", "polished"],
                "additionalProperties": false,
            ],
        ],
    ]

    func polish(
        system: String,
        user: String,
        timeout: TimeInterval = 8,
        maxTokens: Int? = nil,
        configuration: PolishProviderConfiguration? = nil
    ) async throws -> PolishResponse {
        guard let configuration = configuration ?? PolishProviderConfiguration.current() else {
            throw PolishProviderError.notConfigured
        }
        return try await send(
            system: system,
            user: user,
            timeout: timeout,
            maxTokens: maxTokens,
            configuration: configuration,
            structured: configuration.endpoint.supportsStructuredOutputs
        )
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
        maxTokens: Int? = nil,
        configuration: PolishProviderConfiguration,
        structured: Bool = false,
        includeTemperature: Bool = true,
        includeReasoning: Bool = true,
        allowTruncationRetry: Bool = true
    ) async throws -> PolishResponse {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let reasoningEffort: PolishReasoningEffort = includeReasoning ? .current() : .automatic
        let request = try makeRequest(
            system: structured ? system + Self.structuredScanNote : system,
            user: user,
            timeout: timeout,
            maxTokens: maxTokens.map { base in
                var budget = structured ? base + Self.structuredOutputTokenHeadroom : base
                if reasoningEffort.reservesReasoningTokens {
                    budget += Self.reasoningTokenHeadroom
                }
                return budget
            },
            configuration: configuration,
            structured: structured,
            includeTemperature: includeTemperature,
            reasoningEffort: reasoningEffort
        )

        let (data, http) = try await TransientRequestRetry.data(for: request, session: session, engine: "AIPolish")

        guard http.statusCode == 200 else {
            let message = Self.parseErrorMessage(from: data)
            let lowercasedMessage = message.lowercased()
            // Some models/providers reject json_schema; drop to the plain-text
            // contract so the polish still ships.
            if http.statusCode == 400, structured,
                lowercasedMessage.contains("response_format") || lowercasedMessage.contains("schema")
                    || lowercasedMessage.contains("json")
            {
                SapoLog.ai.info("Polish provider rejected structured output — retrying plain")
                return try await send(
                    system: system,
                    user: user,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    configuration: configuration,
                    structured: false,
                    includeTemperature: includeTemperature,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: allowTruncationRetry
                )
            }
            // Reasoning-tier models on some providers reject sampling params;
            // retry once without temperature so "paste a key" still works.
            if http.statusCode == 400, includeTemperature, lowercasedMessage.contains("temperature") {
                SapoLog.ai.info("Polish provider rejected temperature — retrying without it")
                return try await send(
                    system: system,
                    user: user,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    configuration: configuration,
                    structured: structured,
                    includeTemperature: false,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: allowTruncationRetry
                )
            }
            // Not every provider/model accepts reasoning control (Groq and
            // local servers vary per model); drop it so the polish still ships
            // with the model's default behavior.
            if http.statusCode == 400, includeReasoning, reasoningEffort != .automatic,
                lowercasedMessage.contains("reasoning")
            {
                SapoLog.ai.info("Polish provider rejected reasoning effort — retrying without it")
                return try await send(
                    system: system,
                    user: user,
                    timeout: timeout,
                    maxTokens: maxTokens,
                    configuration: configuration,
                    structured: structured,
                    includeTemperature: includeTemperature,
                    includeReasoning: false,
                    allowTruncationRetry: allowTruncationRetry
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
        let content = (choice?.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = structured ? Self.extractStructuredPolished(from: content) : content
        let finishReason = choice?.finishReason ?? "none"
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.ai.info(
            "Polish provider response endpoint=\(configuration.endpoint.rawValue, privacy: .public) structured=\(structured, privacy: .public) reasoning=\(reasoningEffort.rawValue, privacy: .public) finishReason=\(finishReason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(text.count, privacy: .public)"
        )

        // A "length" finish means the output was cut mid-sentence; pasting it
        // would ship a silently truncated polish. Retry once with a doubled
        // cap, then let the caller fall back to the raw text.
        if finishReason == "length" {
            if allowTruncationRetry, let maxTokens {
                SapoLog.ai.warning(
                    "Polish response hit max_tokens cap=\(maxTokens, privacy: .public) — retrying with doubled cap"
                )
                return try await send(
                    system: system,
                    user: user,
                    timeout: timeout,
                    maxTokens: maxTokens * 2,
                    configuration: configuration,
                    structured: structured,
                    includeTemperature: includeTemperature,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: false
                )
            }
            throw PolishProviderError.truncatedResponse
        }

        guard !text.isEmpty else {
            throw PolishProviderError.emptyResponse(finishReason: choice?.finishReason)
        }

        return PolishResponse(text: text, modelIdentifier: configuration.modelIdentifier)
    }

    /// Pulls `polished` out of a structured response body. A model that
    /// ignored the schema (some OpenRouter fallback routes) returns plain
    /// text; keep it as-is and let the sanitizer handle any wrapper noise.
    private static func extractStructuredPolished(from content: String) -> String {
        guard let data = content.data(using: .utf8),
            let payload = try? JSONDecoder().decode(StructuredPolishPayload.self, from: data)
        else {
            return content
        }
        return payload.polished.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRequest(
        system: String,
        user: String,
        timeout: TimeInterval,
        maxTokens: Int?,
        configuration: PolishProviderConfiguration,
        structured: Bool,
        includeTemperature: Bool,
        reasoningEffort: PolishReasoningEffort
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
        if structured {
            body["response_format"] = Self.structuredResponseFormat
        }
        if includeTemperature {
            body["temperature"] = 0.1
        }
        if let maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let effort = reasoningEffort.wireValue {
            switch configuration.endpoint {
            case .openRouter:
                // OpenRouter's normalized reasoning config; exclude keeps the
                // reasoning text out of the response body. Non-reasoning
                // models ignore the whole object.
                body["reasoning"] = ["effort": effort, "exclude": true]
            case .openAI, .groq, .localServer, .custom:
                body["reasoning_effort"] = effort
            }
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

/// Content payload of a structured polish response. `filler_scan` is decoded
/// only to tolerate its presence; it may contain transcript tokens and must
/// never be logged or persisted.
private struct StructuredPolishPayload: Decodable {
    let polished: String

    private enum CodingKeys: String, CodingKey {
        case polished
    }
}

private struct ChatCompletionsErrorEnvelope: Decodable {
    let error: ChatCompletionsErrorBody
}

private struct ChatCompletionsErrorBody: Decodable {
    let message: String
}
