//
//  GoogleCloudTranscriber.swift
//  SapoWhisper
//
//  Created by Steven on 4/4/26.
//

import AVFoundation
import Combine
import Foundation

/// Transcriber using Google Cloud Speech-to-Text
/// - V2 + Chirp 3 when service account is configured
/// - V1 + latest_long when only API key is available
class GoogleCloudTranscriber: ObservableObject {

    @Published var isTranscribing = false

    private let v1BaseURL = "https://speech.googleapis.com/v1/speech:recognize"

    /// Check if any auth method is configured (service account or API key)
    var isConfigured: Bool {
        if ServiceAccountManager.shared.isConfigured { return true }
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.googleCloudAPIKey) ?? ""
        return !key.isEmpty
    }

    /// Whether V2 (Chirp 3) is available
    var isV2Available: Bool {
        ServiceAccountManager.shared.isConfigured
    }

    private func googleLanguageCode(for appLanguage: String) -> String {
        switch appLanguage {
        case "es": return "es-ES"
        case "en": return "en-US"
        case "auto": return "es-ES"
        default: return "es-ES"
        }
    }

    // MARK: - Public API

    /// Routes to V2 (Chirp 3) if service account configured, V1 otherwise
    func transcribe(audioURL: URL, language: String) async throws -> String {
        if ServiceAccountManager.shared.isConfigured {
            return try await transcribeV2(audioURL: audioURL, language: language)
        } else {
            return try await transcribeV1(audioURL: audioURL, language: language)
        }
    }

    // MARK: - V2: Service Account + Chirp 3

    private func transcribeV2(audioURL: URL, language: String, isRetry: Bool = false) async throws -> String {
        let token = try await ServiceAccountManager.shared.getValidAccessToken()
        guard let projectID = ServiceAccountManager.shared.projectID else {
            throw GoogleCloudError.noAPIKey
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // Convert float32 WAV to int16 LINEAR16 for V2
        let pcmData = try convertFloat32ToInt16(audioURL)
        let base64Audio = pcmData.base64EncodedString()
        let estimate = Double(pcmData.count) / (16000.0 * 2.0)

        print("🌐 Google Cloud STT V2 (Chirp 3): sending \(pcmData.count) bytes (~\(String(format: "%.1f", estimate))s)")

        let endpoint = GoogleCloudConfig.v2Endpoint(projectID: projectID)
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let requestBody: [String: Any] = [
            "config": [
                "explicitDecodingConfig": [
                    "encoding": "LINEAR16",
                    "sampleRateHertz": 16000,
                    "audioChannelCount": 1
                ],
                "languageCodes": [googleLanguageCode(for: language)],
                "model": "chirp_3",
                "features": ["enableAutomaticPunctuation": true]
            ],
            "content": base64Audio
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleCloudError.invalidResponse }

        if let str = String(data: data, encoding: .utf8) {
            print("🌐 V2 response (\(http.statusCode)): \(str.prefix(500))")
        }

        // Retry once on 401
        if http.statusCode == 401 && !isRetry {
            return try await transcribeV2(audioURL: audioURL, language: language, isRetry: true)
        }

        if http.statusCode != 200 {
            return try handleError(data: data, statusCode: http.statusCode)
        }
        return try parseResults(data: data, label: "V2")
    }

    // MARK: - V1: API Key + latest_long

    private func transcribeV1(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.googleCloudAPIKey),
              !apiKey.isEmpty else {
            throw GoogleCloudError.noAPIKey
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        let pcmData = try convertFloat32ToInt16(audioURL)
        let base64Audio = pcmData.base64EncodedString()
        let secs = Double(pcmData.count) / (16000.0 * 2.0)

        print("🌐 Google Cloud STT V1 (latest_long): sending \(pcmData.count) bytes (~\(String(format: "%.1f", secs))s)")

        var request = URLRequest(url: URL(string: "\(v1BaseURL)?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "config": [
                "encoding": "LINEAR16",
                "sampleRateHertz": 16000,
                "languageCode": googleLanguageCode(for: language),
                "model": "latest_long",
                "enableAutomaticPunctuation": true
            ],
            "audio": ["content": base64Audio]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleCloudError.invalidResponse }

        if let str = String(data: data, encoding: .utf8) {
            print("🌐 V1 response (\(http.statusCode)): \(str.prefix(500))")
        }

        if http.statusCode != 200 {
            return try handleError(data: data, statusCode: http.statusCode)
        }
        return try parseResults(data: data, label: "V1")
    }

    // MARK: - Helpers

    private func convertFloat32ToInt16(_ audioURL: URL) throws -> Data {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw GoogleCloudError.invalidResponse
        }
        try audioFile.read(into: buffer)
        guard let floatData = buffer.floatChannelData else { throw GoogleCloudError.invalidResponse }

        let samples = Int(buffer.frameLength)
        var int16Data = Data(count: samples * 2)
        int16Data.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for i in 0..<samples {
                buf[i] = Int16(max(-1.0, min(1.0, floatData[0][i])) * 32767.0)
            }
        }
        return int16Data
    }

    private func handleError(data: Data, statusCode: Int) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            if statusCode == 403 || statusCode == 401 {
                throw GoogleCloudError.invalidAPIKey(message)
            } else if statusCode == 429 {
                throw GoogleCloudError.quotaExceeded
            }
            throw GoogleCloudError.apiError(statusCode, message)
        }
        throw GoogleCloudError.apiError(statusCode, "Unknown error")
    }

    private func parseResults(data: Data, label: String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else {
            throw GoogleCloudError.emptyTranscription
        }
        let transcript = results.compactMap { r -> String? in
            (r["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String
        }.joined(separator: " ")

        guard !transcript.isEmpty else { throw GoogleCloudError.emptyTranscription }
        print("🌐 Google Cloud STT \(label) result: \(transcript.prefix(80))...")
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum GoogleCloudError: LocalizedError {
    case noAPIKey, invalidAPIKey(String), quotaExceeded, invalidResponse, emptyTranscription, apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Google Cloud not configured"
        case .invalidAPIKey(let m): return "Auth error: \(m)"
        case .quotaExceeded: return "Google Cloud quota exceeded"
        case .invalidResponse: return "Invalid response from Google Cloud"
        case .emptyTranscription: return "No speech detected"
        case .apiError(let c, let m): return "Google Cloud error (\(c)): \(m)"
        }
    }
}
