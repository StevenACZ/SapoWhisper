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

    /// ElevenLabs Scribe v2 batch keyterm biasing limits: up to 1000 terms,
    /// each ≤50 characters and ≤5 words.
    private static let maxKeyterms = ElevenLabsKeytermLimits.batchMaxCount
    private static let maxKeytermLength = ElevenLabsKeytermLimits.batchMaxLength
    private static let maxKeytermWords = ElevenLabsKeytermLimits.batchMaxWords

    /// Check if the ElevenLabs API key is configured.
    var isConfigured: Bool {
        let key = KeychainStore.string(for: .elevenLabsAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Transcription

    /// Transcribe an audio file using the ElevenLabs Scribe v2 batch endpoint.
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = KeychainStore.string(for: .elevenLabsAPIKey),
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
        let keytermPayload = VocabularyManager.shared.recognitionKeytermPayload(
            maxCount: Self.maxKeyterms,
            maxLength: Self.maxKeytermLength,
            maxWords: Self.maxKeytermWords,
            includeReplacementValues: true
        )
        let keyterms = keytermPayload.terms
        let body = makeMultipartBody(
            boundary: boundary,
            audioData: audioData,
            language: language,
            keyterms: keyterms
        )
        request.httpBody = body

        let startedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.recording.info(
            "ElevenLabs Scribe batch started audioBytes=\(audioData.count, privacy: .public) bodyBytes=\(body.count, privacy: .public) keyterms=\(keyterms.count, privacy: .public) keytermsDropped=\(keytermPayload.droppedCount, privacy: .public) timeout=\(Int(request.timeoutInterval), privacy: .public)s"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-batch-start",
            context:
                "audioBytes=\(audioData.count) bodyBytes=\(body.count) keyterms=\(keyterms.count) keytermsDropped=\(keytermPayload.droppedCount)",
            force: true
        )
        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await TransientRequestRetry.data(for: request, engine: Self.engineName)
        } catch {
            throw TranscriptionFailure.from(error, engine: Self.engineName)
        }

        guard httpResponse.statusCode == 200 else {
            let failure = TranscriptionFailure.fromHTTP(
                engine: Self.engineName, statusCode: httpResponse.statusCode, body: data)
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            SapoLog.recording.error(
                "ElevenLabs Scribe HTTP failure elapsed=\(elapsedMs, privacy: .public)ms \(failure.logSummary, privacy: .public)")
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "elevenlabs-batch-failed",
                context:
                    "elapsedMs=\(elapsedMs) status=\(httpResponse.statusCode) audioBytes=\(audioData.count) failure=\(failure.diagnosticCode)",
                force: true
            )
            throw failure
        }

        // A 200 without parsable text means "nothing was recognized" — surface
        // it as emptyTranscription (not retryable), matching every other engine.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let transcript = json["text"] as? String
        else {
            SapoLog.recording.warning(
                "ElevenLabs Scribe parse failure status=\(httpResponse.statusCode, privacy: .public) audioBytes=\(audioData.count, privacy: .public)"
            )
            throw TranscriptionFailure(
                kind: .emptyTranscription, engine: Self.engineName,
                technicalDetail: "could not parse 200 response bytes=\(data.count)")
        }

        // Scribe v2 has no server-side replace; apply saved vocabulary corrections locally.
        let finalText = VocabularyManager.shared.applyingRecognitionCorrections(to: transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !finalText.isEmpty else {
            throw TranscriptionFailure(
                kind: .emptyTranscription, engine: Self.engineName,
                technicalDetail: "empty transcript in 200 response")
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "request-id") ?? "n/a"
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.recording.info(
            "ElevenLabs Scribe finished requestID=\(requestID, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms audioBytes=\(audioData.count, privacy: .public) chars=\(finalText.count, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-batch-finished",
            context:
                "requestID=\(requestID) elapsedMs=\(elapsedMs) audioBytes=\(audioData.count) responseBytes=\(data.count) chars=\(finalText.count)",
            force: true
        )

        return finalText
    }

    // MARK: - Multipart Body

    private func makeMultipartBody(boundary: String, audioData: Data, language: String, keyterms: [String]) -> Data {
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

        for keyterm in keyterms {
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

    // MARK: - Language Mapping

    /// Maps the app language to a Scribe language code; `nil` lets Scribe auto-detect.
    private func scribeLanguageCode(for appLanguage: String) -> String? {
        TranscriptionLanguageCatalog.elevenLabsLanguageCode(for: appLanguage)
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
