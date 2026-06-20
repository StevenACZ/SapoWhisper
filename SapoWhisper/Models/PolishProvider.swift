//
//  PolishProvider.swift
//  SapoWhisper
//

import Foundation

/// Endpoint presets for the OpenAI-compatible polish provider. Every preset
/// speaks the same `chat/completions` protocol; only the base URL changes.
enum PolishEndpoint: String, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case localServer = "local_server"
    case openAI = "openai"
    case groq
    case custom

    static let `default`: PolishEndpoint = .openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter:
            return "OpenRouter"
        case .localServer:
            return "ai.provider.endpoint_local_server".localized
        case .openAI:
            return "OpenAI"
        case .groq:
            return "Groq"
        case .custom:
            return "ai.provider.endpoint_custom".localized
        }
    }

    /// Preset base URL; `nil` for `.custom` (user supplied, e.g. Ollama/LM Studio).
    var presetBaseURL: String? {
        switch self {
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .localServer:
            return "http://localhost:8081/v1"
        case .openAI:
            return "https://api.openai.com/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .custom:
            return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter:
            return "openai/gpt-5.4-nano"
        case .localServer:
            return "qwen3.6-35b-a3b"
        case .openAI:
            return "gpt-5.4-nano"
        case .groq, .custom:
            return ""
        }
    }

    /// Suggested model IDs for the model menu; free text always wins because
    /// provider catalogs rotate. Any ID from openrouter.ai/models is valid on
    /// OpenRouter — these are just one-click starting points.
    var suggestedModels: [String] {
        switch self {
        case .openRouter:
            return [
                "openai/gpt-5.4-nano",
                "openai/gpt-5.4-mini",
                "google/gemini-2.5-flash-lite",
                "deepseek/deepseek-chat-v3-0324",
                "qwen/qwen3-32b",
                "meta-llama/llama-3.3-70b-instruct",
            ]
        case .openAI:
            return ["gpt-5.4-nano", "gpt-5.4-mini"]
        case .localServer:
            return ["qwen3.6-35b-a3b", "qwen36"]
        case .groq, .custom:
            return []
        }
    }

    /// Local OpenAI-compatible servers (Ollama, LM Studio) accept requests
    /// without an API key; hosted presets require one.
    var requiresAPIKey: Bool {
        self != .custom && self != .localServer
    }

    /// Hosted presets need internet; custom endpoints may be LAN-only.
    var requiresInternet: Bool {
        self != .custom && self != .localServer
    }
}

/// Resolved polish provider settings (endpoint + model + key), read from
/// UserDefaults and the Keychain at request time.
struct PolishProviderConfiguration {
    let endpoint: PolishEndpoint
    let baseURL: URL
    let model: String
    let apiKey: String

    /// Identifier persisted in history metadata, e.g. `openrouter/openai/gpt-5.4-nano`.
    var modelIdentifier: String { "\(endpoint.rawValue)/\(model)" }

    var requiresInternet: Bool { endpoint.requiresInternet }

    static func current(defaults: UserDefaults = .standard) -> PolishProviderConfiguration? {
        let endpointValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishEndpoint) ?? PolishEndpoint.default.rawValue
        let endpoint = PolishEndpoint(rawValue: endpointValue) ?? .default
        let model = (defaults.string(forKey: Constants.StorageKeys.aiPolishModel) ?? endpoint.defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let customBaseURL = (defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (KeychainStore.string(for: .aiPolishAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isUsable(endpoint: endpoint, model: model, customBaseURL: customBaseURL, apiKey: apiKey),
            let baseURL = URL(string: endpoint.presetBaseURL ?? customBaseURL)
        else {
            return nil
        }

        return PolishProviderConfiguration(endpoint: endpoint, baseURL: baseURL, model: model, apiKey: apiKey)
    }

    static func currentEndpoint(defaults: UserDefaults = .standard) -> PolishEndpoint {
        let endpointValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishEndpoint) ?? PolishEndpoint.default.rawValue
        return PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    static func hostedEndpointIsPausedOffline(
        defaults: UserDefaults = .standard,
        isOffline: Bool = NetworkReachability.shared.isOffline
    ) -> Bool {
        defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
            && isOffline
            && currentEndpoint(defaults: defaults).requiresInternet
    }

    /// Like `current() != nil`, but checks key presence through KeychainStore's
    /// hints so launch and settings surfaces can gate on it without triggering
    /// a keychain consent prompt.
    static func hasUsableConfiguration(defaults: UserDefaults = .standard) -> Bool {
        let endpointValue =
            defaults.string(forKey: Constants.StorageKeys.aiPolishEndpoint) ?? PolishEndpoint.default.rawValue
        let endpoint = PolishEndpoint(rawValue: endpointValue) ?? .default
        let model = defaults.string(forKey: Constants.StorageKeys.aiPolishModel) ?? endpoint.defaultModel
        let customBaseURL = defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL) ?? ""
        // isUsable only checks key presence, so a placeholder stands in for it.
        let apiKey = KeychainStore.hasValue(for: .aiPolishAPIKey) ? "stored" : ""
        return isUsable(endpoint: endpoint, model: model, customBaseURL: customBaseURL, apiKey: apiKey)
    }

    /// Single source of truth for "can this combination make a request",
    /// shared by the request path and the settings UI.
    static func isUsable(endpoint: PolishEndpoint, model: String, customBaseURL: String, apiKey: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }

        if endpoint.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        let baseURLString = endpoint.presetBaseURL ?? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: baseURLString), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return false
        }
        return scheme == "https" || scheme == "http"
    }
}
