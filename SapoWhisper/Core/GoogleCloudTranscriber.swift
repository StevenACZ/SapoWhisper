//
//  GoogleCloudTranscriber.swift
//  SapoWhisper
//
//  Created by Steven on 4/4/26.
//

import Combine
import Foundation

/// Transcriber using Google Cloud Speech-to-Text API with Chirp model
class GoogleCloudTranscriber: ObservableObject {

    @Published var isTranscribing = false

    /// Google Cloud STT API endpoint
    private let baseURL = "https://speech.googleapis.com/v1/speech:recognize"

    /// Check if API key is configured
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.googleCloudAPIKey) ?? ""
        return !key.isEmpty
    }

    /// Maps app language codes to Google Cloud language codes
    private func googleLanguageCode(for appLanguage: String) -> String {
        switch appLanguage {
        case "es": return "es-ES"
        case "en": return "en-US"
        case "auto": return "es-ES" // Default, Chirp handles detection
        default: return "es-ES"
        }
    }

    /// Transcribes audio file using Google Cloud Speech-to-Text
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.googleCloudAPIKey),
              !apiKey.isEmpty else {
            throw GoogleCloudError.noAPIKey
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // Read audio file and encode to base64
        let audioData = try Data(contentsOf: audioURL)
        let base64Audio = audioData.base64EncodedString()

        // Build request
        let url = URL(string: "\(baseURL)?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": 16000,
                "languageCode": googleLanguageCode(for: language),
                "model": "chirp",
                "enableAutomaticPunctuation": true
            ],
            "audio": [
                "content": base64Audio
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCloudError.invalidResponse
        }

        // Handle errors
        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {

                if httpResponse.statusCode == 403 || httpResponse.statusCode == 401 {
                    throw GoogleCloudError.invalidAPIKey(message)
                } else if httpResponse.statusCode == 429 {
                    throw GoogleCloudError.quotaExceeded
                } else {
                    throw GoogleCloudError.apiError(httpResponse.statusCode, message)
                }
            }
            throw GoogleCloudError.apiError(httpResponse.statusCode, "Unknown error")
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw GoogleCloudError.emptyTranscription
        }

        // Concatenate all transcript parts
        let transcript = results.compactMap { result -> String? in
            guard let alternatives = result["alternatives"] as? [[String: Any]],
                  let firstAlt = alternatives.first,
                  let text = firstAlt["transcript"] as? String else {
                return nil
            }
            return text
        }.joined(separator: " ")

        guard !transcript.isEmpty else {
            throw GoogleCloudError.emptyTranscription
        }

        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum GoogleCloudError: LocalizedError {
    case noAPIKey
    case invalidAPIKey(String)
    case quotaExceeded
    case invalidResponse
    case emptyTranscription
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "Google Cloud API key not configured"
        case .invalidAPIKey(let msg):
            return "Invalid API key: \(msg)"
        case .quotaExceeded:
            return "Google Cloud quota exceeded"
        case .invalidResponse:
            return "Invalid response from Google Cloud"
        case .emptyTranscription:
            return "No speech detected"
        case .apiError(let code, let msg):
            return "Google Cloud error (\(code)): \(msg)"
        }
    }
}
