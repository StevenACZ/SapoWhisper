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

    static var hasUsableConfiguration: Bool {
        normalizedBaseURL(from: storedBaseURL) != nil
            && !storedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func normalizedBaseURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }
        return url
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
