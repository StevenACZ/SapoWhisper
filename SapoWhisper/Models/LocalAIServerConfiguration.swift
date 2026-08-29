//
//  LocalAIServerConfiguration.swift
//  SapoWhisper
//

import Foundation

nonisolated enum LocalAIServerConfiguration {
    static let defaultModel = "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo"

    static let suggestedModels: [String] = [
        "rtlingo/mobiuslabsgmbh-faster-whisper-large-v3-turbo",
        "Systran/faster-distil-whisper-large-v3",
        "Systran/faster-whisper-large-v3",
        "Systran/faster-whisper-small",
    ]

    static var storedBaseURL: String {
        UserDefaults.standard.string(forKey: Constants.StorageKeys.localAIServerBaseURL) ?? ""
    }

    static var storedModel: String {
        let model = UserDefaults.standard.object(forKey: Constants.StorageKeys.localAIServerModel) as? String ?? defaultModel
        return model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static var hasUsableConfiguration: Bool {
        let bearerToken = KeychainStore.hasValue(for: .localAIServerAPIKey) ? "stored" : ""
        return normalizedBaseURL(from: storedBaseURL, apiKey: bearerToken) != nil
            && !storedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalizedBaseURL(from value: String, apiKey: String = "") -> URL? {
        ProviderURLSecurity.validatedURL(from: value, bearerToken: apiKey)
    }

    static func sanitizedBaseURLForStorage(_ value: String) -> String {
        ProviderURLSecurity.sanitizedForStorage(value)
    }

    static func setStoredBaseURL(_ value: String, defaults: UserDefaults = .standard) {
        defaults.set(sanitizedBaseURLForStorage(value), forKey: Constants.StorageKeys.localAIServerBaseURL)
    }

    static func sanitizeStoredBaseURL(defaults: UserDefaults = .standard) {
        guard let stored = defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL) else { return }
        let sanitized = sanitizedBaseURLForStorage(stored)
        if sanitized != stored {
            defaults.set(sanitized, forKey: Constants.StorageKeys.localAIServerBaseURL)
        }
    }

    static func apiRootURL(from baseURL: URL) -> URL {
        let withoutTrailingSlash = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalized = URL(string: withoutTrailingSlash) else { return baseURL }
        if normalized.lastPathComponent.lowercased() == "v1" {
            return normalized
        }
        return normalized.appendingPathComponent("v1")
    }

    static func serviceRootURL(from baseURL: URL) -> URL {
        let apiRoot = apiRootURL(from: baseURL)
        if apiRoot.lastPathComponent.lowercased() == "v1" {
            return apiRoot.deletingLastPathComponent()
        }
        return baseURL
    }

    static func transcriptionsURL(from baseURL: URL) -> URL {
        apiRootURL(from: baseURL).appendingPathComponent("audio/transcriptions")
    }

    static func modelsURL(from baseURL: URL) -> URL {
        apiRootURL(from: baseURL).appendingPathComponent("models")
    }

    static func healthURL(from baseURL: URL) -> URL {
        serviceRootURL(from: baseURL).appendingPathComponent("health")
    }
}
