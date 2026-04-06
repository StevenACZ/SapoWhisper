//
//  DeepgramStreamingTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation

/// Batch transcription via Deepgram Nova-3 REST API
class DeepgramStreamingTranscriber: ObservableObject {

    @Published var isTranscribing: Bool = false

    /// Check if Deepgram API key is configured
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Transcription

    /// Transcribe audio file using Deepgram REST API (pre-recorded)
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey),
              !apiKey.isEmpty else {
            throw DeepgramError.notConfigured
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // Read audio file
        let audioData = try Data(contentsOf: audioURL)

        // Build URL with query parameters
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: deepgramLanguageCode(for: language)),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        // Add vocabulary
        queryItems.append(contentsOf: VocabularyManager.shared.keytermQueryItems())
        queryItems.append(contentsOf: VocabularyManager.shared.replaceQueryItems())

        components.queryItems = queryItems

        guard let url = components.url else {
            throw DeepgramError.invalidURL
        }

        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audioData

        print("Deepgram REST: sending \(audioData.count) bytes (\(deepgramLanguageCode(for: language)))")

        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.apiError("Invalid response")
        }

        // Handle HTTP errors
        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw DeepgramError.invalidAPIKey
        case 429:
            throw DeepgramError.quotaExceeded
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DeepgramError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let firstChannel = channels.first,
              let alternatives = firstChannel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String else {
            throw DeepgramError.apiError("Could not parse response")
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Deepgram REST: transcript received (\(trimmed.count) chars)")
        return trimmed
    }

    // MARK: - Language Mapping

    private func deepgramLanguageCode(for appLanguage: String) -> String {
        switch appLanguage {
        case "es": return "es"
        case "en": return "en"
        case "auto": return "multi"
        default: return "es"
        }
    }
}

// MARK: - Errors

enum DeepgramError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidAPIKey
    case quotaExceeded
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Deepgram API key not configured"
        case .invalidURL:
            return "Invalid Deepgram URL"
        case .invalidAPIKey:
            return "error.deepgram_auth".localized
        case .quotaExceeded:
            return "Deepgram: Quota exceeded"
        case .apiError(let message):
            return "Deepgram: \(message)"
        }
    }
}
