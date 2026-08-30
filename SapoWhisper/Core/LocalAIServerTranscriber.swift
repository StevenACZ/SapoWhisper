//
//  LocalAIServerTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation
import os

struct LocalAIServerConnectionResult: Equatable {
    let modelIDs: [String]
    let selectedModel: String

    var modelAvailable: Bool {
        modelIDs.contains(selectedModel)
    }
}

enum LocalAIServerConnectionError: LocalizedError {
    case invalidBaseURL
    case invalidResponse(String)
    case server(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "local_ai_server.error_invalid_url".localized
        case .invalidResponse(let detail):
            return "local_ai_server.error_invalid_response".localized(detail)
        case .server(let statusCode, let body):
            return "local_ai_server.error_http".localized(String(statusCode), body)
        }
    }
}

final class LocalAIServerTranscriber: ObservableObject {

    @Published var isTranscribing = false

    nonisolated private static let engineName = "Local AI Server"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var isConfigured: Bool {
        LocalAIServerConfiguration.hasUsableConfiguration
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        let apiKey = KeychainStore.string(for: .localAIServerAPIKey) ?? ""
        guard
            let baseURL = LocalAIServerConfiguration.normalizedBaseURL(
                from: LocalAIServerConfiguration.storedBaseURL,
                apiKey: apiKey)
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        let model = LocalAIServerConfiguration.storedModel
        guard !model.isEmpty else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }
        try AudioFileValidator.validate(audioURL)

        isTranscribing = true
        defer { isTranscribing = false }

        // Fail fast when the server is unreachable (host off, LAN change):
        // without this, a blackholed upload waits the full scaled request
        // timeout (2-10 min) before reporting anything.
        try await preflightServerReachability(baseURL: baseURL, apiKey: apiKey)

        // Reading the WAV and copying it into the multipart body is heavy for
        // long takes, so the request is assembled off the main actor.
        let payload = try await Self.makeTranscriptionRequest(
            baseURL: baseURL,
            model: model,
            audioURL: audioURL,
            languageCode: TranscriptionLanguageCatalog.whisperLanguageCode(for: language),
            vocabularyPrompt: VocabularyManager.shared.initialPromptText(),
            apiKey: apiKey
        )
        var request = payload.request
        request.timeoutInterval = TranscriptionFailure.requestTimeout(forAudioBytes: payload.audioByteCount)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await TransientRequestRetry.data(
                for: request,
                session: session,
                engine: Self.engineName
            )
        } catch {
            throw TranscriptionFailure.from(error, engine: Self.engineName)
        }

        guard httpResponse.statusCode == 200 else {
            let failure = TranscriptionFailure.fromHTTP(
                engine: Self.engineName,
                statusCode: httpResponse.statusCode,
                body: data
            )
            SapoLog.recording.error(
                "Local AI Server HTTP failure \(failure.logSummary, privacy: .public)")
            throw failure
        }

        let transcript = try parseTranscript(from: data)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionFailure(
                kind: .emptyTranscription,
                engine: Self.engineName,
                technicalDetail: "empty text in 200 response"
            )
        }
        return trimmed
    }

    func testConnection(baseURL rawBaseURL: String, model: String, apiKey: String) async throws
        -> LocalAIServerConnectionResult
    {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = LocalAIServerConfiguration.normalizedBaseURL(from: rawBaseURL, apiKey: apiKey),
            !trimmedModel.isEmpty
        else {
            throw LocalAIServerConnectionError.invalidBaseURL
        }

        try await probe(url: LocalAIServerConfiguration.healthURL(from: baseURL), apiKey: apiKey)
        let modelIDs = try await fetchModels(baseURL: baseURL, apiKey: apiKey)
        return LocalAIServerConnectionResult(modelIDs: modelIDs, selectedModel: trimmedModel)
    }

    /// Form fields sent with every transcription request. Kept as a pure
    /// helper so tests can pin the anti-hallucination contract: `vad_filter`
    /// makes the server skip non-speech before decoding, which is what stops
    /// Whisper from hallucinating "Thank you." on silent takes and from
    /// looping on the trailing silence of short ones. The vocabulary stays in
    /// `prompt` — hotwords-only requests lose punctuation/casing on a large
    /// fraction of normal regression fixtures.
    nonisolated static func transcriptionFormFields(
        model: String,
        languageCode: String?,
        vocabularyPrompt: String
    ) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [
            ("model", model),
            ("response_format", "json"),
            ("vad_filter", "true"),
        ]
        if let languageCode {
            fields.append(("language", languageCode))
        }
        if !vocabularyPrompt.isEmpty {
            fields.append(("prompt", vocabularyPrompt))
        }
        return fields
    }

    /// Reads the recorded WAV and assembles the multipart request off the main
    /// actor; only Sendable values (URL, strings, Data) cross the boundary.
    @concurrent
    private static func makeTranscriptionRequest(
        baseURL: URL,
        model: String,
        audioURL: URL,
        languageCode: String?,
        vocabularyPrompt: String,
        apiKey: String
    ) async throws -> (request: URLRequest, audioByteCount: Int) {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = LocalAIServerConfiguration.transcriptionsURL(from: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        for field in transcriptionFormFields(
            model: model, languageCode: languageCode, vocabularyPrompt: vocabularyPrompt)
        {
            appendFormField(name: field.name, value: field.value, boundary: boundary, to: &body)
        }
        appendFileField(
            name: "file",
            filename: "recording.wav",
            contentType: "audio/wav",
            data: audioData,
            boundary: boundary,
            to: &body
        )
        body.appendUTF8("--\(boundary)--\r\n")
        request.httpBody = body
        return (request, audioData.count)
    }

    /// Standalone reachability probe, run while the user is still dictating so
    /// a dead server is known BEFORE the upload would start: the backup engine
    /// then takes the dictation without it paying the preflight wait. Same
    /// contract as the pre-upload preflight; never throws, and an
    /// unconfigured server reports nothing rather than a false "down".
    func probeReachability() async -> Bool? {
        let apiKey = KeychainStore.string(for: .localAIServerAPIKey) ?? ""
        guard
            let baseURL = LocalAIServerConfiguration.normalizedBaseURL(
                from: LocalAIServerConfiguration.storedBaseURL,
                apiKey: apiKey)
        else { return nil }

        do {
            try await preflightServerReachability(
                baseURL: baseURL,
                apiKey: apiKey
            )
            return true
        } catch {
            return Task.isCancelled ? nil : false
        }
    }

    /// Cheap GET to `/health` with a short timeout before uploading audio.
    /// ANY HTTP response — including 404 on servers without that endpoint —
    /// proves the host is alive and lets the real request proceed; only
    /// transport-level failures (refused, unreachable, timed out) throw.
    nonisolated static let preflightTimeout: TimeInterval = 3
    private func preflightServerReachability(baseURL: URL, apiKey: String) async throws {
        var request = URLRequest(url: LocalAIServerConfiguration.healthURL(from: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.preflightTimeout
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            _ = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            let detail = LogSanitizer.errorDiagnostic(error, state: "local-preflight")
            let failure = TranscriptionFailure(
                kind: .network,
                engine: Self.engineName,
                technicalDetail: detail
            )
            SapoLog.recording.error(
                "Local AI Server preflight failed \(failure.logSummary, privacy: .public)")
            throw failure
        }
    }

    private func probe(url: URL, apiKey: String) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIServerConnectionError.invalidResponse("missing HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LocalAIServerConnectionError.server(
                statusCode: http.statusCode,
                body: Self.redactedBodySnippet(from: data)
            )
        }
    }

    private func fetchModels(baseURL: URL, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: LocalAIServerConfiguration.modelsURL(from: baseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalAIServerConnectionError.invalidResponse("missing HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw LocalAIServerConnectionError.server(
                statusCode: http.statusCode,
                body: Self.redactedBodySnippet(from: data)
            )
        }

        guard let decoded = try? JSONDecoder().decode(LocalAIModelsResponse.self, from: data) else {
            throw LocalAIServerConnectionError.invalidResponse("could not parse /v1/models")
        }
        return decoded.data.map(\.id).sorted()
    }

    private func parseTranscript(from data: Data) throws -> String {
        if let decoded = try? JSONDecoder().decode(LocalAITranscriptionResponse.self, from: data),
            let text = decoded.text
        {
            return text
        }
        if let plainText = String(data: data, encoding: .utf8),
            !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else {
                throw TranscriptionFailure(
                    kind: .emptyTranscription,
                    engine: Self.engineName,
                    technicalDetail: "missing text field in JSON response bytes=\(data.count)"
                )
            }
            return plainText
        }
        throw TranscriptionFailure(
            kind: .emptyTranscription,
            engine: Self.engineName,
            technicalDetail: "could not parse 200 response bytes=\(data.count)"
        )
    }

    private static func redactedBodySnippet(from data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? "empty response"
        return TranscriptionFailure.redactedLogSnippet(from: body)
    }

    nonisolated private static func appendFormField(name: String, value: String, boundary: String, to body: inout Data) {
        let safeValue =
            value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8("\(safeValue)\r\n")
    }

    nonisolated private static func appendFileField(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n")
    }
}

// MARK: - TranscriptionEngineSession

extension LocalAIServerTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isConfigured }
    var isBusy: Bool { isTranscribing }
}

private struct LocalAITranscriptionResponse: Decodable {
    let text: String?
}

private struct LocalAIModelsResponse: Decodable {
    let data: [LocalAIModel]
}

private struct LocalAIModel: Decodable {
    let id: String
}

nonisolated extension Data {
    fileprivate mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
