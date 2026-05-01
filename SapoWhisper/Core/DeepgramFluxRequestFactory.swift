//
//  DeepgramFluxRequestFactory.swift
//  SapoWhisper
//

import Foundation

enum DeepgramFluxRequestFactory {
    static func makeWebSocketTask(apiKey: String) -> URLSessionWebSocketTask {
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
            URLQueryItem(name: "language_hint", value: "es"),
            URLQueryItem(name: "language_hint", value: "en"),
        ]
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
