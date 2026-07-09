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
    nonisolated private static let engineName = "ElevenLabs"

    /// ElevenLabs Scribe v2 batch keyterm biasing limits: up to 1000 terms,
    /// each ≤50 characters and ≤5 words.
    private static let maxKeyterms = ElevenLabsKeytermLimits.batchMaxCount
    private static let maxKeytermLength = ElevenLabsKeytermLimits.batchMaxLength
    private static let maxKeytermWords = ElevenLabsKeytermLimits.batchMaxWords

    /// Check if the ElevenLabs API key is configured (hint-based: no keychain prompt).
    var isConfigured: Bool {
        KeychainStore.hasValue(for: .elevenLabsAPIKey)
    }

    // MARK: - Transcription

    /// Transcribe an audio file using the ElevenLabs Scribe v2 batch endpoint.
    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard let apiKey = KeychainStore.string(for: .elevenLabsAPIKey),
            !apiKey.isEmpty
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        isTranscribing = true
        defer { isTranscribing = false }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text") else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName, technicalDetail: "invalid endpoint URL")
        }

        let boundary = "----SapoWhisperBoundary\(UUID().uuidString)"
        let keytermPayload = VocabularyManager.shared.recognitionKeytermPayload(
            maxCount: Self.maxKeyterms,
            maxLength: Self.maxKeytermLength,
            maxWords: Self.maxKeytermWords,
            includeReplacementValues: true
        )
        let keyterms = keytermPayload.terms

        // Reading the WAV and copying it into the multipart body is heavy for
        // long takes, so the payload is assembled off the main actor.
        let payload = try await Self.makeUploadPayload(
            audioURL: audioURL,
            boundary: boundary,
            languageCode: scribeLanguageCode(for: language),
            keyterms: keyterms
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Scale the timeout to the clip length so long recordings are not aborted early.
        request.timeoutInterval = TranscriptionFailure.requestTimeout(forAudioBytes: payload.audioByteCount)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload.body

        let audioByteCount = payload.audioByteCount
        let startedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.recording.info(
            "ElevenLabs Scribe batch started audioBytes=\(audioByteCount, privacy: .public) bodyBytes=\(payload.body.count, privacy: .public) keyterms=\(keyterms.count, privacy: .public) keytermsDropped=\(keytermPayload.droppedCount, privacy: .public) timeout=\(Int(request.timeoutInterval), privacy: .public)s"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-batch-start",
            context:
                "audioBytes=\(audioByteCount) bodyBytes=\(payload.body.count) keyterms=\(keyterms.count) keytermsDropped=\(keytermPayload.droppedCount)",
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
                    "elapsedMs=\(elapsedMs) status=\(httpResponse.statusCode) audioBytes=\(audioByteCount) failure=\(failure.diagnosticCode)",
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
                "ElevenLabs Scribe parse failure status=\(httpResponse.statusCode, privacy: .public) audioBytes=\(audioByteCount, privacy: .public)"
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
            "ElevenLabs Scribe finished requestID=\(requestID, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms audioBytes=\(audioByteCount, privacy: .public) chars=\(finalText.count, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-batch-finished",
            context:
                "requestID=\(requestID) elapsedMs=\(elapsedMs) audioBytes=\(audioByteCount) responseBytes=\(data.count) chars=\(finalText.count)",
            force: true
        )

        return finalText
    }

    // MARK: - Connection Warm-Up

    /// Opens DNS+TLS to the API host while the user is still dictating, so a
    /// cold connection pool never sits inside stop→paste. No auth, response
    /// ignored — only the handshake matters (URLSession reuses it).
    func warmUpConnection() async {
        guard let url = URL(string: "https://api.elevenlabs.io") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Multipart Body

    /// Reads the recorded WAV and assembles the multipart body off the main
    /// actor; only Sendable values (URL, strings, Data) cross the boundary.
    @concurrent
    private static func makeUploadPayload(
        audioURL: URL,
        boundary: String,
        languageCode: String?,
        keyterms: [String]
    ) async throws -> (body: Data, audioByteCount: Int) {
        // Batch Scribe accepts the WAV produced by the selected upload-quality profile.
        let audioData = try Data(contentsOf: audioURL)
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model_id", "scribe_v2")
        appendField("tag_audio_events", "false")
        appendField("timestamps_granularity", "none")
        // Deterministic decoding for dictation (the endpoint accepts 0-2).
        appendField("temperature", "0")

        if let languageCode {
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
        return (body, audioData.count)
    }

    // MARK: - Language Mapping

    /// Maps the app language to a Scribe language code; `nil` lets Scribe auto-detect.
    private func scribeLanguageCode(for appLanguage: String) -> String? {
        TranscriptionLanguageCatalog.elevenLabsLanguageCode(for: appLanguage)
    }
}

// MARK: - TranscriptionEngineSession

extension ElevenLabsScribeTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isConfigured }
    var isBusy: Bool { isTranscribing }
}

// MARK: - Data Helper

nonisolated extension Data {
    fileprivate mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
