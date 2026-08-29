//
//  PolishProvider.swift
//  SapoWhisper
//

import Foundation

enum PolishModelEvidenceTier: String {
    case bestTested
    case bestValue
    case sameLanguageValue
    case fastBudget
    case economy
    case notRecommended

    nonisolated var displayName: String {
        "ai.provider.model_tier_\(rawValue)".localized
    }
}

nonisolated struct PolishModelRecommendation: Identifiable, Hashable {
    let model: String
    let tier: PolishModelEvidenceTier
    let detailKey: String
    let isSuggested: Bool
    var benchmarkedReasoning: PolishReasoningEffort = .off
    var minimumReasoning: PolishReasoningEffort? = nil

    var id: String { model }
    var detail: String { detailKey.localized }
}

enum PolishModelCatalog {
    /// Verified on OpenRouter 2026-08-29: these reject `reasoning: none` with
    /// HTTP 400 "Reasoning is mandatory for this endpoint and cannot be
    /// disabled", so the request retries without the field and runs with the
    /// model's own (slow) default budget.
    static let reasoningMandatoryModels: Set<String> = [
        "x-ai/grok-4.6",
        "qwen/qwen3.8-max",
        "z-ai/glm-5.3-flash",
        "google/gemini-3.7-flash",
    ]

    static func requiresReasoning(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if reasoningMandatoryModels.contains(normalized) { return true }
        return reasoningMandatoryModels.contains { $0.split(separator: "/").last.map(String.init) == normalized }
    }

    static func reasoningPolicy(
        for modelID: String,
        provider: PolishEndpoint
    ) -> (benchmarked: PolishReasoningEffort, minimum: PolishReasoningEffort?) {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let mandatoryMinimum: PolishReasoningEffort? = requiresReasoning(normalized) ? .low : nil

        guard let recommendation = provider.modelRecommendation(for: normalized) else {
            return (.automatic, mandatoryMinimum)
        }
        return (recommendation.benchmarkedReasoning, recommendation.minimumReasoning ?? mandatoryMinimum)
    }
}

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
        case .openRouter, .localServer, .openAI, .groq, .custom:
            return ""
        }
    }

    fileprivate var legacyDefaultModel: String {
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
        modelRecommendations.filter(\.isSuggested).map(\.model)
    }

    var modelRecommendations: [PolishModelRecommendation] {
        switch self {
        case .openRouter:
            return [
                PolishModelRecommendation(
                    model: "anthropic/claude-opus-5",
                    tier: .bestTested,
                    detailKey: "ai.provider.model_detail_opus5",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "openai/gpt-5.6-sol",
                    tier: .bestValue,
                    detailKey: "ai.provider.model_detail_sol",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "qwen/qwen3.8-flash",
                    tier: .sameLanguageValue,
                    detailKey: "ai.provider.model_detail_qwen38",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "openai/gpt-5.4-nano",
                    tier: .fastBudget,
                    detailKey: "ai.provider.model_detail_nano",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "qwen/qwen3.5-flash-02-23",
                    tier: .economy,
                    detailKey: "ai.provider.model_detail_qwen35",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "z-ai/glm-5.3-flash",
                    tier: .notRecommended,
                    detailKey: "ai.provider.model_detail_failed_gates",
                    isSuggested: false,
                    benchmarkedReasoning: .automatic,
                    minimumReasoning: .low
                ),
                PolishModelRecommendation(
                    model: "deepseek/deepseek-v4-flash-0731",
                    tier: .notRecommended,
                    detailKey: "ai.provider.model_detail_failed_gates",
                    isSuggested: false
                ),
                PolishModelRecommendation(
                    model: "openai/gpt-5.6-luna",
                    tier: .notRecommended,
                    detailKey: "ai.provider.model_detail_failed_gates",
                    isSuggested: false
                ),
            ]
        case .openAI:
            return [
                PolishModelRecommendation(
                    model: "gpt-5.6-sol",
                    tier: .bestValue,
                    detailKey: "ai.provider.model_detail_sol",
                    isSuggested: true
                ),
                PolishModelRecommendation(
                    model: "gpt-5.4-nano",
                    tier: .fastBudget,
                    detailKey: "ai.provider.model_detail_nano",
                    isSuggested: true
                ),
            ]
        case .localServer, .groq, .custom:
            return []
        }
    }

    func modelRecommendation(for model: String) -> PolishModelRecommendation? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelRecommendations.first { $0.model == normalized }
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
            ([defaultModel] + suggestedModels + legacySuggestedModels)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
    }

    private var legacySuggestedModels: [String] {
        switch self {
        case .openRouter:
            return [
                "openai/gpt-5.4-mini",
                "google/gemini-2.5-flash-lite",
                "deepseek/deepseek-chat-v3-0324",
                "qwen/qwen3-32b",
                "meta-llama/llama-3.3-70b-instruct",
            ]
        case .openAI:
            return ["gpt-5.4-mini"]
        case .localServer:
            return ["qwen3.6-35b-a3b", "qwen36"]
        case .groq, .custom:
            return []
        }
    }
}

/// Global reasoning budget for the polish request. Reasoning models (Mercury,
/// GPT-5.x, Grok, Qwen thinking) spend output tokens thinking before they
/// write, which both slows the polish and eats the `max_tokens` cap sized for
/// the polished text. Off is the default: a dictation polish needs no chain of
/// thought. Providers that reject the parameter get one retry without it, and
/// non-reasoning models ignore it, so any effort value is safe on any model.
enum PolishReasoningEffort: String, CaseIterable, Identifiable {
    case automatic
    case off
    case low
    case medium
    case high

    static let `default`: PolishReasoningEffort = .off

    var id: String { rawValue }

    /// Wire value shared by OpenRouter (`reasoning.effort`) and the plain
    /// OpenAI/Groq `reasoning_effort` parameter. `automatic` sends nothing.
    var wireValue: String? {
        switch self {
        case .automatic:
            return nil
        case .off:
            return "none"
        case .low, .medium, .high:
            return rawValue
        }
    }

    /// True when the request explicitly asks the model to reason, so the
    /// output token cap must reserve room for the reasoning tokens.
    var reservesReasoningTokens: Bool {
        self == .low || self == .medium || self == .high
    }

    nonisolated var displayName: String {
        "ai.polish.reasoning_\(rawValue)".localized
    }

    nonisolated func coerced(toMinimum minimum: PolishReasoningEffort?) -> PolishReasoningEffort {
        switch minimum {
        case .low, .medium, .high:
            break
        case .automatic, .off, nil:
            return self
        }
        switch self {
        case .automatic, .off:
            return minimum ?? self
        case .low, .medium, .high:
            return self
        }
    }

    static func current(defaults: UserDefaults = .standard) -> PolishReasoningEffort {
        let stored = defaults.string(forKey: Constants.StorageKeys.aiPolishReasoningEffort)
        return stored.flatMap(PolishReasoningEffort.init(rawValue:)) ?? .default
    }
}

/// One selectable "polish with…" target: an endpoint the user has configured
/// plus one of the models they have used on it. Drives the model menu on the
/// history "Improve with AI" button.
nonisolated struct PolishModelOption: Identifiable, Hashable {
    let endpoint: PolishEndpoint
    let model: String

    var id: String { "\(endpoint.rawValue)/\(model)" }
    var displayName: String { "\(endpoint.displayName) · \(model)" }
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
        configuration(
            for: currentEndpoint(defaults: defaults),
            model: nil,
            defaults: defaults
        )
    }

    static func migrateExplicitModelSelection(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Constants.StorageKeys.aiPolishExplicitModelMigration) else { return }
        defaults.set(true, forKey: Constants.StorageKeys.aiPolishExplicitModelMigration)
        guard defaults.bool(forKey: Constants.StorageKeys.onboardingComplete) else { return }

        let endpoint = currentEndpoint(defaults: defaults)
        guard storedModel(for: endpoint, defaults: defaults).isEmpty else { return }
        let legacyModel = endpoint.legacyDefaultModel
        guard !legacyModel.isEmpty else { return }
        setStoredModel(legacyModel, for: endpoint, defaults: defaults)
    }

    /// Resolves a usable configuration for an explicit endpoint/model pair —
    /// the history "polish with…" menu re-polishes with any configured
    /// provider without touching the global selection. `model: nil` uses the
    /// endpoint's stored model (the `current()` path).
    static func configuration(
        for endpoint: PolishEndpoint,
        model: String?,
        defaults: UserDefaults = .standard
    ) -> PolishProviderConfiguration? {
        let model = model ?? storedModel(for: endpoint, defaults: defaults)
        let baseURLInput = storedBaseURLInput(for: endpoint, defaults: defaults)
        let apiKey = apiKey(for: endpoint, allowLegacyFallback: true)

        guard isUsable(endpoint: endpoint, model: model, customBaseURL: baseURLInput, apiKey: apiKey),
            let baseURL = validatedBaseURL(endpoint: endpoint, input: baseURLInput, apiKey: apiKey)
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
        guard let baseURL = validatedBaseURL(endpoint: endpoint, input: baseURLInput, apiKey: "") else {
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

        return validatedBaseURL(endpoint: endpoint, input: customBaseURL, apiKey: apiKey) != nil
    }

    // MARK: - Recent models

    /// Models that actually completed a polish on each endpoint, newest first.
    /// Recorded at use time (never while typing in Settings, which would fill
    /// the list with partial names); the history "polish with…" menu reads it
    /// so a model stays offered after the user moves the endpoint to another.
    static func recentModels(for endpoint: PolishEndpoint, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: recentModelsStorageKey(for: endpoint)) ?? []
    }

    static func recordRecentModel(_ model: String, for endpoint: PolishEndpoint, defaults: UserDefaults = .standard) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var models = recentModels(for: endpoint, defaults: defaults).filter { $0 != trimmed }
        models.insert(trimmed, at: 0)
        defaults.set(Array(models.prefix(8)), forKey: recentModelsStorageKey(for: endpoint))
    }

    /// Every endpoint/model pair the user can re-polish with right now: each
    /// configured endpoint contributes its current model plus its recents.
    /// Gates on key-presence hints only — building a menu must never trigger
    /// a keychain consent prompt.
    static func availableModelOptions(defaults: UserDefaults = .standard) -> [PolishModelOption] {
        let current = currentEndpoint(defaults: defaults)
        let endpoints = [current] + PolishEndpoint.allCases.filter { $0 != current }

        var options: [PolishModelOption] = []
        for endpoint in endpoints {
            let stored = storedModel(for: endpoint, defaults: defaults)
            let apiKey = hasAPIKeyHint(for: endpoint) ? "stored" : ""
            let baseURL = storedBaseURLInput(for: endpoint, defaults: defaults)
            var models: [String] = []
            for model in [stored] + recentModels(for: endpoint, defaults: defaults) {
                guard !models.contains(model),
                    isUsable(endpoint: endpoint, model: model, customBaseURL: baseURL, apiKey: apiKey)
                else { continue }
                models.append(model)
            }
            options.append(contentsOf: models.map { PolishModelOption(endpoint: endpoint, model: $0) })
        }
        return options
    }

    private static func recentModelsStorageKey(for endpoint: PolishEndpoint) -> String {
        Constants.StorageKeys.aiPolishEndpointRecentModelsPrefix + endpoint.rawValue
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
        let safeValue = sanitizedBaseURLForStorage(baseURL)
        defaults.set(safeValue, forKey: baseURLStorageKey(for: endpoint))
        if endpoint == .custom {
            defaults.set(safeValue, forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
        }
    }

    static func sanitizeStoredBaseURLs(defaults: UserDefaults = .standard) {
        for endpoint in PolishEndpoint.allCases where endpoint.usesEditableBaseURL {
            let key = baseURLStorageKey(for: endpoint)
            guard let stored = defaults.string(forKey: key) else { continue }
            let sanitized = sanitizedBaseURLForStorage(stored)
            if sanitized != stored {
                defaults.set(sanitized, forKey: key)
            }
        }

        if let legacy = defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL) {
            let sanitized = sanitizedBaseURLForStorage(legacy)
            if sanitized != legacy {
                defaults.set(sanitized, forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
            }
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

    static func validatedBaseURL(endpoint: PolishEndpoint, input: String, apiKey: String) -> URL? {
        let value = resolvedBaseURLString(for: endpoint, input: input)
        return ProviderURLSecurity.validatedURL(from: value, bearerToken: apiKey)
    }

    static func sanitizedBaseURLForStorage(_ input: String) -> String {
        ProviderURLSecurity.sanitizedForStorage(input)
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
