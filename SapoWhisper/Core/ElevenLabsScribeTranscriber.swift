//
//  ElevenLabsScribeTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation
import os

/// Batch transcription via ElevenLabs Scribe v2 REST API.
/// Push-to-talk flow: uploads the recorded WAV and returns the final transcript.
class ElevenLabsScribeTranscriber: ObservableObject {

    @Published var isTranscribing: Bool = false

    /// Brand name surfaced in user-facing failures and logs.
    private static let engineName = "ElevenLabs"

    /// ElevenLabs Scribe v2 keyterm biasing limits: up to 100 terms,
    /// each ≤50 characters and ≤5 words.
    private static let maxKeyterms = 100
    private static let maxKeytermLength = 50
    private static let maxKeytermWords = 5

    /// Check if the ElevenLabs API key is configured.
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.elevenLabsAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Transcription

    /// Transcribe an audio file using the ElevenLabs Scribe v2 batch endpoint.
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.elevenLabsAPIKey),
            !apiKey.isEmpty
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        await MainActor.run { isTranscribing = true }
        defer { Task { @MainActor in isTranscribing = false } }

        // The recorder already produces int16 16 kHz mono WAV, so no conversion is needed.
        let audioData = try Data(contentsOf: audioURL)

        guard let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName, technicalDetail: "invalid endpoint URL")
        }

        let boundary = "----SapoWhisperBoundary\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Scale the timeout to the clip length so long recordings are not aborted early.
        request.timeoutInterval = TranscriptionFailure.requestTimeout(forAudioBytes: audioData.count)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            language: language
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionFailure.from(error, engine: Self.engineName)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName, technicalDetail: "non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let failure = TranscriptionFailure.fromHTTP(
                engine: Self.engineName, statusCode: httpResponse.statusCode, body: data)
            SapoLog.recording.error(
                "ElevenLabs Scribe HTTP failure \(failure.logSummary, privacy: .public)")
            throw failure
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transcript = json["text"] as? String
        else {
            SapoLog.recording.warning(
                "ElevenLabs Scribe parse failure status=\(httpResponse.statusCode, privacy: .public) audioBytes=\(audioData.count, privacy: .public)"
            )
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName,
                technicalDetail: "could not parse 200 response bytes=\(data.count)")
        }

        // Scribe v2 has no server-side replace; apply saved replacements locally.
        let finalText = VocabularyManager.shared.applyingReplacements(to: transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let requestID = httpResponse.value(forHTTPHeaderField: "request-id") ?? "n/a"
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.recording.info(
            "ElevenLabs Scribe finished requestID=\(requestID, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms audioBytes=\(audioData.count, privacy: .public) chars=\(finalText.count, privacy: .public)"
        )

        return finalText
    }

    // MARK: - Multipart Body

    private func makeMultipartBody(boundary: String, audioData: Data, language: String) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model_id", "scribe_v2")
        appendField("tag_audio_events", "false")
        appendField("timestamps_granularity", "none")

        if let languageCode = scribeLanguageCode(for: language) {
            appendField("language_code", languageCode)
        }

        for keyterm in sanitizedKeyterms() {
            appendField("keyterms", keyterm)
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")
        return body
    }

    /// Keyterms from the shared vocabulary, capped to the Scribe v2 limits.
    /// An out-of-bounds keyterm would make the API reject the whole request,
    /// so terms over the length/word limits are dropped rather than truncated.
    private func sanitizedKeyterms() -> [String] {
        VocabularyManager.shared.keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                !term.isEmpty
                    && term.count <= Self.maxKeytermLength
                    && term.split(separator: " ").count <= Self.maxKeytermWords
            }
            .prefix(Self.maxKeyterms)
            .map { $0 }
    }

    // MARK: - Language Mapping

    /// Maps the app language to an ISO-639-1 code; `nil` lets Scribe auto-detect.
    private func scribeLanguageCode(for appLanguage: String) -> String? {
        switch appLanguage {
        case "es": return "es"
        case "en": return "en"
        case "auto": return nil
        default: return nil
        }
    }
}

// MARK: - Data Helper

extension Data {
    fileprivate mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
