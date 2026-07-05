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

    nonisolated var displayName: String {
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

    /// Default base URL. Local/custom endpoints may override this in Settings.
    var defaultBaseURL: String {
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
            return ""
        }
    }

    /// Fixed hosted presets use their provider URL; local/custom endpoints are
    /// editable because they often point to a LAN machine or local app.
    nonisolated var usesEditableBaseURL: Bool {
        self == .localServer || self == .custom
    }

    /// Legacy name kept for tests and export/import compatibility.
    var presetBaseURL: String? {
        self == .custom ? nil : defaultBaseURL
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

    /// Custom endpoints often still need bearer auth. The local server preset
    /// stays uncluttered by default because most LAN servers are unauthenticated.
    var showsAPIKeyByDefault: Bool {
        self != .localServer
    }

    /// Hosted presets need internet; custom endpoints may be LAN-only.
    var requiresInternet: Bool {
        self != .custom && self != .localServer
    }

    /// OpenAI and OpenRouter reliably honor `response_format: json_schema`
    /// (strict). Groq/local/custom servers vary by model, so they keep the
    /// plain-text contract; the polisher also falls back to plain text if a
    /// structured request is rejected.
    nonisolated var supportsStructuredOutputs: Bool {
        self == .openAI || self == .openRouter
    }

    var apiKeychainKey: KeychainStore.Key {
        switch self {
        case .openRouter:
            return .aiPolishOpenRouterAPIKey
        case .localServer:
            return .aiPolishLocalServerAPIKey
        case .openAI:
            return .aiPolishOpenAIAPIKey
        case .groq:
            return .aiPolishGroqAPIKey
        case .custom:
            return .aiPolishCustomAPIKey
        }
    }

    fileprivate var managedModels: Set<String> {
        Set(
            ([defaultModel] + suggestedModels).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
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

    var usesLocalTimeoutBudget: Bool {
        endpoint == .localServer || Self.isLocalNetworkHost(baseURL.host)
    }

    static func current(defaults: UserDefaults = .standard) -> PolishProviderConfiguration? {
        let endpoint = currentEndpoint(defaults: defaults)
        let model = storedModel(for: endpoint, defaults: defaults)
        let baseURLInput = storedBaseURLInput(for: endpoint, defaults: defaults)
        let apiKey = apiKey(for: endpoint, allowLegacyFallback: true)

        guard isUsable(endpoint: endpoint, model: model, customBaseURL: baseURLInput, apiKey: apiKey),
            let baseURL = URL(string: resolvedBaseURLString(for: endpoint, input: baseURLInput))
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

    static func configuredEndpointUsesLocalTimeoutBudget(defaults: UserDefaults = .standard) -> Bool {
        let endpoint = currentEndpoint(defaults: defaults)
        guard endpoint != .localServer else { return true }

        let baseURLInput = storedBaseURLInput(for: endpoint, defaults: defaults)
        guard let baseURL = URL(string: resolvedBaseURLString(for: endpoint, input: baseURLInput)) else {
            return false
        }
        return isLocalNetworkHost(baseURL.host)
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
        let model = storedModel(for: endpoint, defaults: defaults)
        let customBaseURL = storedBaseURLInput(for: endpoint, defaults: defaults)
        // isUsable only checks key presence, so a placeholder stands in for it.
        let apiKey = hasAPIKeyHint(for: endpoint) ? "stored" : ""
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

        let baseURLString = resolvedBaseURLString(for: endpoint, input: customBaseURL)
        guard let url = URL(string: baseURLString), let scheme = url.scheme?.lowercased(), url.host != nil else {
            return false
        }
        return scheme == "https" || scheme == "http"
    }

    static func storedModel(
        for endpoint: PolishEndpoint,
        defaults: UserDefaults = .standard,
        allowLegacyFallback: Bool = true
    ) -> String {
        let scoped = (defaults.string(forKey: modelStorageKey(for: endpoint)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !scoped.isEmpty { return scoped }

        if allowLegacyFallback, endpoint == currentEndpoint(defaults: defaults) {
            let legacy = (defaults.string(forKey: Constants.StorageKeys.aiPolishModel) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty, !isModelManagedByAnotherPreset(legacy, endpoint: endpoint) {
                return legacy
            }
        }

        return endpoint.defaultModel
    }

    static func setStoredModel(_ model: String, for endpoint: PolishEndpoint, defaults: UserDefaults = .standard) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: modelStorageKey(for: endpoint))
        if endpoint == currentEndpoint(defaults: defaults) {
            defaults.set(trimmed, forKey: Constants.StorageKeys.aiPolishModel)
        }
    }

    static func storedBaseURLInput(
        for endpoint: PolishEndpoint,
        defaults: UserDefaults = .standard,
        allowLegacyFallback: Bool = true
    ) -> String {
        guard endpoint.usesEditableBaseURL else { return endpoint.defaultBaseURL }

        let scoped = (defaults.string(forKey: baseURLStorageKey(for: endpoint)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !scoped.isEmpty { return scoped }

        if allowLegacyFallback, endpoint == .custom {
            return (defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return endpoint.defaultBaseURL
    }

    static func setStoredBaseURLInput(_ baseURL: String, for endpoint: PolishEndpoint, defaults: UserDefaults = .standard) {
        guard endpoint.usesEditableBaseURL else { return }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: baseURLStorageKey(for: endpoint))
        if endpoint == .custom {
            defaults.set(trimmed, forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
        }
    }

    static func apiKey(for endpoint: PolishEndpoint, allowLegacyFallback: Bool = false) -> String {
        let scoped = (KeychainStore.string(for: endpoint.apiKeychainKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !scoped.isEmpty { return scoped }

        guard allowLegacyFallback, endpoint.requiresAPIKey else { return "" }
        let legacy = (KeychainStore.string(for: .aiPolishAPIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyAPIKeyLooksCompatible(legacy, with: endpoint) ? legacy : ""
    }

    static func hasAPIKeyHint(for endpoint: PolishEndpoint) -> Bool {
        KeychainStore.hasValue(for: endpoint.apiKeychainKey)
    }

    static func resolvedBaseURLString(for endpoint: PolishEndpoint, input: String) -> String {
        guard endpoint.usesEditableBaseURL else { return endpoint.defaultBaseURL }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? endpoint.defaultBaseURL : trimmed
    }

    private static func modelStorageKey(for endpoint: PolishEndpoint) -> String {
        Constants.StorageKeys.aiPolishEndpointModelPrefix + endpoint.rawValue
    }

    private static func baseURLStorageKey(for endpoint: PolishEndpoint) -> String {
        Constants.StorageKeys.aiPolishEndpointBaseURLPrefix + endpoint.rawValue
    }

    private static func isModelManagedByAnotherPreset(_ model: String, endpoint: PolishEndpoint) -> Bool {
        PolishEndpoint.allCases
            .filter { $0 != endpoint && $0 != .custom }
            .contains { $0.managedModels.contains(model) }
    }

    private static func legacyAPIKeyLooksCompatible(_ key: String, with endpoint: PolishEndpoint) -> Bool {
        guard !key.isEmpty else { return false }
        switch endpoint {
        case .openRouter:
            return key.hasPrefix("sk-or-")
        case .openAI:
            return !key.hasPrefix("sk-or-") && !key.hasPrefix("gsk_")
        case .groq:
            return key.hasPrefix("gsk_")
        case .localServer, .custom:
            return false
        }
    }

    private static func isLocalNetworkHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") {
            return true
        }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 || parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}
