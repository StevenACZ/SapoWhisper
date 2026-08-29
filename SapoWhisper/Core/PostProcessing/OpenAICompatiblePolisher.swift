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
    let responseCount: Int
}

enum PolishProviderError: LocalizedError {
    case notConfigured
    case emptyResponse(finishReason: String?)
    case truncatedResponse
    case invalidStructuredResponse
    case translationFailed
    case httpError(statusCode: Int, endpoint: PolishEndpoint, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "ai.provider.error_not_configured".localized
        case .emptyResponse:
            return "ai.provider.error_empty".localized
        case .truncatedResponse:
            return "ai.provider.error_truncated".localized
        case .invalidStructuredResponse:
            return "ai.provider.error_invalid_structured".localized
        case .translationFailed:
            return "ai.provider.error_translation_failed".localized
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

    /// The structured contract per polish mode: a leading scan field forces a
    /// whole-transcript attention pass before the final text is written. The
    /// normal contract scans fillers; the compact contract inventories the
    /// requirements that must survive compression (benched 2026-07-05).
    enum StructuredContract {
        case polish
        case compact

        var scanNote: String {
            switch self {
            case .polish:
                return """


                    Return a JSON object. First fill `filler_scan`: list every filler occurrence you found while scanning the whole transcript. Then fill `polished` with the final cleaned text — every filler you listed must be gone from it.
                    """
            case .compact:
                return """


                    Return a JSON object. First fill `requirements_scan`: inventory every instruction, decision, question, condition, number, name, path and URL in the whole transcript. Then fill `compact` with the shortest faithful text — every item you listed must appear in it.
                    """
            }
        }

        var responseFormat: [String: Any] {
            switch self {
            case .polish:
                return Self.format(
                    name: "polish",
                    scanKey: "filler_scan",
                    scanDescription:
                        "Comma-separated list of every filler occurrence you found in the transcript (e.g. 'eh x3, como se dice x2, digamos x1'). Scan the WHOLE transcript before writing the polished text. Count 'como se dice' every single time, including when it introduces a term ('eso es como se dice el happy path' → 'eso es el happy path') — it is always filler.",
                    textKey: "polished",
                    textDescription: "The final cleaned text, and nothing else."
                )
            case .compact:
                return Self.format(
                    name: "compact",
                    scanKey: "requirements_scan",
                    scanDescription:
                        "Semicolon-separated inventory of EVERY distinct instruction, decision, question, condition, number, name, path and URL in the WHOLE transcript — one terse item each, in your own words, NOT copied fragments. Scan the whole transcript before writing — every item listed here must survive in `compact`.",
                    textKey: "compact",
                    textDescription: "The final compact text, and nothing else."
                )
            }
        }

        private static func format(
            name: String,
            scanKey: String,
            scanDescription: String,
            textKey: String,
            textDescription: String
        ) -> [String: Any] {
            [
                "type": "json_schema",
                "json_schema": [
                    "name": name,
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": [
                            scanKey: ["type": "string", "description": scanDescription],
                            textKey: ["type": "string", "description": textDescription],
                        ],
                        "required": [scanKey, textKey],
                        "additionalProperties": false,
                    ],
                ],
            ]
        }
    }

    func polish(
        system: String,
        user: String,
        timeout: TimeInterval = 8,
        maxTokens: Int? = nil,
        configuration: PolishProviderConfiguration? = nil,
        contract: StructuredContract = .polish,
        maximumResponses: Int? = nil
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
            structured: configuration.endpoint.supportsStructuredOutputs,
            contract: contract,
            maximumResponses: maximumResponses
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
        contract: StructuredContract = .polish,
        includeTemperature: Bool = true,
        includeReasoning: Bool = true,
        allowTruncationRetry: Bool = true,
        responseCount: Int = 0,
        maximumResponses: Int? = nil
    ) async throws -> PolishResponse {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let reasoningEffort: PolishReasoningEffort = includeReasoning ? .current() : .automatic
        let request = try makeRequest(
            system: structured ? system + contract.scanNote : system,
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
            contract: contract,
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
                    contract: contract,
                    includeTemperature: includeTemperature,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: allowTruncationRetry,
                    responseCount: responseCount,
                    maximumResponses: maximumResponses
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
                    contract: contract,
                    includeTemperature: false,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: allowTruncationRetry,
                    responseCount: responseCount,
                    maximumResponses: maximumResponses
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
                    contract: contract,
                    includeTemperature: includeTemperature,
                    includeReasoning: false,
                    allowTruncationRetry: allowTruncationRetry,
                    responseCount: responseCount,
                    maximumResponses: maximumResponses
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
        let finishReason = choice?.finishReason ?? "none"
        let completedResponseCount = responseCount + 1

        // A "length" finish means the output was cut mid-sentence; pasting it
        // would ship a silently truncated polish. Retry once with a doubled
        // cap, then let the caller fall back to the raw text.
        if finishReason == "length" {
            if allowTruncationRetry, let maxTokens,
                maximumResponses.map({ completedResponseCount < $0 }) ?? true
            {
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
                    contract: contract,
                    includeTemperature: includeTemperature,
                    includeReasoning: includeReasoning,
                    allowTruncationRetry: false,
                    responseCount: completedResponseCount,
                    maximumResponses: maximumResponses
                )
            }
            throw PolishProviderError.truncatedResponse
        }

        let text: String
        do {
            text = try structured ? Self.extractStructuredText(from: content, contract: contract) : content
        } catch PolishProviderError.invalidStructuredResponse where structured {
            guard maximumResponses.map({ completedResponseCount < $0 }) ?? true else {
                throw PolishProviderError.invalidStructuredResponse
            }
            SapoLog.ai.info("Polish provider returned invalid structured output — retrying plain")
            return try await send(
                system: system,
                user: user,
                timeout: timeout,
                maxTokens: maxTokens,
                configuration: configuration,
                structured: false,
                contract: contract,
                includeTemperature: includeTemperature,
                includeReasoning: includeReasoning,
                allowTruncationRetry: allowTruncationRetry,
                responseCount: completedResponseCount,
                maximumResponses: maximumResponses
            )
        }
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.ai.info(
            "Polish provider response endpoint=\(configuration.endpoint.rawValue, privacy: .public) structured=\(structured, privacy: .public) reasoning=\(reasoningEffort.rawValue, privacy: .public) finishReason=\(finishReason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(text.count, privacy: .public)"
        )

        guard !text.isEmpty else {
            throw PolishProviderError.emptyResponse(finishReason: choice?.finishReason)
        }

        return PolishResponse(
            text: text,
            modelIdentifier: configuration.modelIdentifier,
            responseCount: completedResponseCount
        )
    }

    private static func extractStructuredText(
        from content: String,
        contract: StructuredContract
    ) throws -> String {
        let fenced = unwrapStructuredFence(from: content)
        let candidate = fenced?.body ?? content
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSONEnvelope =
            fenced?.declaresJSON == true
            || trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
        guard isJSONEnvelope else { return content }
        guard let data = trimmed.data(using: .utf8) else {
            throw PolishProviderError.invalidStructuredResponse
        }

        guard let decoded = try? JSONSerialization.jsonObject(with: data),
            let object = decoded as? [String: Any]
        else {
            throw PolishProviderError.invalidStructuredResponse
        }

        let expectedKeys: Set<String>
        let scanKey: String
        let textKey: String
        switch contract {
        case .polish:
            expectedKeys = ["filler_scan", "polished"]
            scanKey = "filler_scan"
            textKey = "polished"
        case .compact:
            expectedKeys = ["requirements_scan", "compact"]
            scanKey = "requirements_scan"
            textKey = "compact"
        }
        guard Set(object.keys) == expectedKeys,
            object[scanKey] is String,
            let text = object[textKey] as? String
        else {
            throw PolishProviderError.invalidStructuredResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapStructuredFence(from content: String) -> (body: String, declaresJSON: Bool)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return nil }
        guard let firstLineEnd = trimmed.firstIndex(of: "\n") else { return nil }
        let fenceLabel = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<firstLineEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fenceLabel.isEmpty || fenceLabel.caseInsensitiveCompare("json") == .orderedSame else { return nil }
        let closingStart = trimmed.index(trimmed.endIndex, offsetBy: -3)
        return (
            String(trimmed[trimmed.index(after: firstLineEnd)..<closingStart]),
            fenceLabel.caseInsensitiveCompare("json") == .orderedSame
        )
    }

    private func makeRequest(
        system: String,
        user: String,
        timeout: TimeInterval,
        maxTokens: Int?,
        configuration: PolishProviderConfiguration,
        structured: Bool,
        contract: StructuredContract,
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
            body["response_format"] = contract.responseFormat
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

private struct ChatCompletionsErrorEnvelope: Decodable {
    let error: ChatCompletionsErrorBody
}

private struct ChatCompletionsErrorBody: Decodable {
    let message: String
}
