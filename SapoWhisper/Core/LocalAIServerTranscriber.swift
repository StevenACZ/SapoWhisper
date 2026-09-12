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
    private let reachabilitySession: URLSession
    private let ownsReachabilitySession: Bool

    init(session: URLSession? = nil) {
        self.session = session ?? .shared
        reachabilitySession = session ?? URLSession(configuration: Self.reachabilityConfiguration())
        ownsReachabilitySession = session == nil
    }

    deinit {
        if ownsReachabilitySession { reachabilitySession.invalidateAndCancel() }
    }

    nonisolated static func reachabilityConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = preflightTimeout
        configuration.timeoutIntervalForResource = preflightTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
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

        let payload: (request: URLRequest, body: FileMultipartBody)
        do {
            payload = try await Self.makeTranscriptionRequest(
                baseURL: baseURL,
                model: model,
                audioURL: audioURL,
                languageCode: TranscriptionLanguageCatalog.whisperLanguageCode(for: language),
                vocabularyPrompt: VocabularyManager.shared.initialPromptText(),
                apiKey: apiKey
            )
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw TranscriptionFailure(
                kind: .audioPreparationFailed, engine: Self.engineName,
                technicalDetail: LogSanitizer.errorDiagnostic(error, state: "prepare-upload")
            )
        }
        defer { payload.body.remove() }
        var request = payload.request
        request.timeoutInterval = TranscriptionFailure.requestTimeout(forAudioBytes: payload.body.audioByteCount)

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await TransientRequestRetry.upload(
                for: request,
                fromFile: payload.body.fileURL,
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

    @concurrent
    static func makeTranscriptionRequest(
        baseURL: URL,
        model: String,
        audioURL: URL,
        languageCode: String?,
        vocabularyPrompt: String,
        apiKey: String
    ) async throws -> (request: URLRequest, body: FileMultipartBody) {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = LocalAIServerConfiguration.transcriptionsURL(from: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let body = try FileMultipartBody.create(
            audioURL: audioURL,
            fields: transcriptionFormFields(model: model, languageCode: languageCode, vocabularyPrompt: vocabularyPrompt),
            boundary: boundary
        )
        return (request, body)
    }

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
            if !Task.isCancelled {
                SapoLog.recording.notice("Local AI Server background probe inconclusive; transcription will confirm availability")
            }
            return nil
        }
    }

    /// Cheap GET to `/health` with a short timeout before uploading audio.
    /// ANY HTTP response — including 404 on servers without that endpoint —
    /// proves the host is alive and lets the real request proceed; only
    /// transport-level failures (refused, unreachable, timed out) throw.
    nonisolated static let preflightTimeout: TimeInterval = 3
    private func preflightServerReachability(baseURL: URL, apiKey: String) async throws {
        do {
            _ = try await checkReachability(url: LocalAIServerConfiguration.healthURL(from: baseURL), apiKey: apiKey)
        } catch {
            try Task.checkCancellation()
            let detail = LogSanitizer.errorDiagnostic(error, state: "local-preflight")
            let failure = TranscriptionFailure(kind: .network, engine: Self.engineName, technicalDetail: detail)
            SapoLog.recording.error("Local AI Server preflight failed \(failure.logSummary, privacy: .public)")
            throw failure
        }
    }

    private func checkReachability(url: URL, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty { request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization") }
        let preparedRequest = request
        let deadline = ProcessInfo.processInfo.systemUptime + Self.preflightTimeout
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask {
                try await self.performReachabilityChecks(request: preparedRequest, deadline: deadline)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.preflightTimeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private func performReachabilityChecks(
        request initialRequest: URLRequest, deadline: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let backoffs: [TimeInterval] = [0.35, 0.8]
        var request = initialRequest
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw URLError(.timedOut) }
            request.timeoutInterval = remaining
            do {
                let (data, response) = try await reachabilitySession.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            } catch let error as URLError {
                try Task.checkCancellation()
                guard attempt < backoffs.count,
                    TransientRequestRetry.retryableURLErrorCodes.contains(error.code),
                    deadline - ProcessInfo.processInfo.systemUptime > backoffs[attempt]
                else { throw error }
                let delay = backoffs[attempt]
                attempt += 1
                SapoLog.recording.notice(
                    "Local AI Server preflight confirming transient failure code=\(error.code.rawValue, privacy: .public) attempt=\(attempt + 1, privacy: .public)/3"
                )
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func probe(url: URL, apiKey: String) async throws {
        let (data, http) = try await checkReachability(url: url, apiKey: apiKey)
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
