//
//  DeepgramFluxRequestFactory.swift
//  SapoWhisper
//

import Foundation

enum DeepgramFluxRequestFactory {
    static func makeWebSocketTask(apiKey: String, language: String) -> URLSessionWebSocketTask {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v2/listen"
        components.queryItems = [
            URLQueryItem(name: "model", value: "flux-general-multi"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "eot_threshold", value: "0.7"),
            URLQueryItem(name: "eot_timeout_ms", value: "1000"),
        ]
        if let languageHint = TranscriptionLanguageCatalog.deepgramFluxLanguageHint(for: language) {
            components.queryItems?.append(URLQueryItem(name: "language_hint", value: languageHint))
        } else if language == "auto" {
            // Flux documents `language_hint` as repeatable and recommends
            // sending every expected language for bilingual speakers, so auto
            // mode hints the user's es+en profile instead of none.
            components.queryItems?.append(URLQueryItem(name: "language_hint", value: "es"))
            components.queryItems?.append(URLQueryItem(name: "language_hint", value: "en"))
        }
        components.queryItems?.append(contentsOf: VocabularyManager.shared.keytermQueryItems())

        guard let url = components.url else {
            preconditionFailure("Invalid Deepgram Flux URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return URLSession.shared.webSocketTask(with: request)
    }
}
