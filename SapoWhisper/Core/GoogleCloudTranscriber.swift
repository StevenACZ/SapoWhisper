//
//  GoogleCloudTranscriber.swift
//  SapoWhisper
//
//  Created by Steven on 4/4/26.
//

import AVFoundation
import Combine
import Foundation

/// Transcriber using Google Cloud Speech-to-Text API
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
        case "auto": return "es-ES"
        default: return "es-ES"
        }
    }

    /// Converts float32 PCM samples to int16 PCM (LINEAR16) for Google Cloud API
    private func convertFloat32ToInt16(_ audioURL: URL) throws -> Data {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw GoogleCloudError.invalidResponse
        }
        try audioFile.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw GoogleCloudError.invalidResponse
        }

        let samples = Int(buffer.frameLength)
        var int16Data = Data(count: samples * 2)

        int16Data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<samples {
                let sample = floatData[0][i]
                let clamped = max(-1.0, min(1.0, sample))
                int16Buffer[i] = Int16(clamped * 32767.0)
            }
        }

        return int16Data
    }

    /// Transcribes audio file using Google Cloud Speech-to-Text
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.googleCloudAPIKey),
              !apiKey.isEmpty else {
            throw GoogleCloudError.noAPIKey
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // Convert float32 WAV to int16 PCM (LINEAR16)
        let pcmData = try convertFloat32ToInt16(audioURL)
        let base64Audio = pcmData.base64EncodedString()
        let durationSecs = Double(pcmData.count) / (16000.0 * 2.0)

        print("🌐 Google Cloud STT: sending \(pcmData.count) bytes (~\(String(format: "%.1f", durationSecs))s of audio)")

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
                "model": "latest_short",
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

        // Log raw response for debugging
        if let responseStr = String(data: data, encoding: .utf8) {
            print("🌐 Google Cloud STT response (\(httpResponse.statusCode)): \(responseStr.prefix(500))")
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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleCloudError.emptyTranscription
        }

        guard let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            print("🌐 Google Cloud STT: no results in response")
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

        print("🌐 Google Cloud STT result: \(transcript.prefix(80))...")
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
