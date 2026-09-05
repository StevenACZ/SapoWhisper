//
//  LocalAIServerTests.swift
//  SapoWhisperTests
//

import XCTest
import os

@testable import SapoWhisper

@MainActor
final class LocalAIServerTests: XCTestCase {

    func testLocalAIServerEndpointNormalizationAcceptsRootBaseURL() throws {
        let baseURL = try XCTUnwrap(LocalAIServerConfiguration.normalizedBaseURL(from: "http://127.0.0.1:8000"))

        XCTAssertEqual(
            LocalAIServerConfiguration.healthURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/health"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.modelsURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/v1/models"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.transcriptionsURL(from: baseURL).absoluteString,
            "http://127.0.0.1:8000/v1/audio/transcriptions"
        )
    }

    func testLocalAIServerEndpointNormalizationAcceptsVersionedBaseURL() throws {
        let baseURL = try XCTUnwrap(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000/v1/"))

        XCTAssertEqual(
            LocalAIServerConfiguration.healthURL(from: baseURL).absoluteString,
            "http://localhost:8000/health"
        )
        XCTAssertEqual(
            LocalAIServerConfiguration.modelsURL(from: baseURL).absoluteString,
            "http://localhost:8000/v1/models"
        )
    }

    func testLocalAIServerEndpointNormalizationRejectsAmbiguousBaseURLParts() {
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://user:pass@localhost:8000"))
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000?debug=true"))
        XCTAssertNil(LocalAIServerConfiguration.normalizedBaseURL(from: "http://localhost:8000#health"))
    }

    func testLocalAIServerBearerTransportRequiresHTTPSOutsideLoopback() {
        XCTAssertNil(
            LocalAIServerConfiguration.normalizedBaseURL(
                from: "http://192.0.2.20:8000",
                apiKey: "local-token"
            )
        )
        XCTAssertNotNil(
            LocalAIServerConfiguration.normalizedBaseURL(
                from: "http://192.0.2.20:8000",
                apiKey: ""
            )
        )
        XCTAssertNotNil(
            LocalAIServerConfiguration.normalizedBaseURL(
                from: "http://127.0.0.1:8000",
                apiKey: "local-token"
            )
        )
        XCTAssertNotNil(
            LocalAIServerConfiguration.normalizedBaseURL(
                from: "https://transcription.example:8000",
                apiKey: "hosted-token"
            )
        )
    }

    func testLocalAIServerStoredURLMigrationSanitizesSensitiveComponents() throws {
        let suiteName = "test.sapowhisper.local-url-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "https://user:secret@transcription.example/v1?token=private#fragment",
            forKey: Constants.StorageKeys.localAIServerBaseURL
        )

        LocalAIServerConfiguration.sanitizeStoredBaseURL(defaults: defaults)
        LocalAIServerConfiguration.sanitizeStoredBaseURL(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL),
            "https://transcription.example/v1"
        )
    }

    @MainActor
    func testConnectionRejectsPlainHTTPLANBearerBeforeMakingRequest() async {
        StubURLProtocol.handler = { _ in
            XCTFail("An insecure provider URL must be rejected before a request is created")
            return .failure(URLError(.badURL))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeStubbedTranscriber().testConnection(
                baseURL: "http://192.0.2.20:8000",
                model: "test-model",
                apiKey: "local-token"
            )
            XCTFail("Expected invalidBaseURL")
        } catch let error as LocalAIServerConnectionError {
            guard case .invalidBaseURL = error else {
                return XCTFail("Expected invalidBaseURL, got \(error)")
            }
        } catch {
            XCTFail("Expected LocalAIServerConnectionError, got \(error)")
        }
    }

    func testEngineFilterHasLocalAIBucket() {
        XCTAssertTrue(EngineFilter.localAI.matches("Local AI Server · mobiuslabsgmbh/faster-whisper-large-v3-turbo"))
        XCTAssertFalse(EngineFilter.other.matches("Local AI Server"))
    }

    // MARK: - Transcription form fields

    func testTranscriptionRequestAlwaysEnablesVADFilter() {
        // vad_filter is the layer that stops Whisper from hallucinating
        // ("Thank you.", repetition loops) on silent or short takes —
        // Covered by the silent/short-take regression contract. Do not drop it.
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "faster-whisper", languageCode: nil, vocabularyPrompt: "")
        XCTAssertTrue(fields.contains { $0.name == "vad_filter" && $0.value == "true" })
        XCTAssertTrue(fields.contains { $0.name == "model" && $0.value == "faster-whisper" })
        XCTAssertTrue(fields.contains { $0.name == "response_format" && $0.value == "json" })
    }

    func testTranscriptionRequestOmitsEmptyOptionalFields() {
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "m", languageCode: nil, vocabularyPrompt: "")
        XCTAssertFalse(fields.contains { $0.name == "language" })
        XCTAssertFalse(fields.contains { $0.name == "prompt" })
    }

    func testTranscriptionRequestIncludesLanguageAndPromptWhenSet() {
        let fields = LocalAIServerTranscriber.transcriptionFormFields(
            model: "m", languageCode: "es", vocabularyPrompt: "Glossary: SapoWhisper.")
        XCTAssertTrue(fields.contains { $0.name == "language" && $0.value == "es" })
        XCTAssertTrue(fields.contains { $0.name == "prompt" && $0.value == "Glossary: SapoWhisper." })
    }

    func testFileUploadRequestKeepsAuthorizationOutOfMultipartAndPreservesFields() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audio = try Data(contentsOf: audioURL)
        let payload = try await LocalAIServerTranscriber.makeTranscriptionRequest(
            baseURL: URL(string: "https://transcription.example/v1")!,
            model: "fixture-model", audioURL: audioURL, languageCode: "es",
            vocabularyPrompt: "Glossary: fixture.\r\nNext line.", apiKey: "  fixture-bearer-only  "
        )
        defer { payload.body.remove() }
        XCTAssertEqual(payload.request.url?.path, "/v1/audio/transcriptions")
        XCTAssertEqual(payload.request.httpMethod, "POST")
        XCTAssertEqual(payload.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer-only")
        XCTAssertNil(payload.request.httpBody)
        XCTAssertNil(payload.request.httpBodyStream)
        XCTAssertEqual(payload.body.audioByteCount, audio.count)
        let contentType = try XCTUnwrap(payload.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        let data = try Data(contentsOf: payload.body.fileURL)
        let text = String(decoding: data, as: UTF8.self)
        for (name, value) in [
            ("model", "fixture-model"), ("response_format", "json"), ("vad_filter", "true"),
            ("language", "es"), ("prompt", "Glossary: fixture.  Next line."),
        ] {
            XCTAssertTrue(text.contains("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"))
        }
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        XCTAssertFalse(text.contains("fixture-bearer-only"))
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
    }

    func testFileUploadRetriesTransientTransportAndServerFailures() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let body = try FileMultipartBody.create(audioURL: audioURL, fields: [], boundary: "Retry")
        defer { body.remove() }
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let bodyURL = body.fileURL
        StubURLProtocol.handler = { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: bodyURL.path))
            let attempt = attempts.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 { return .failure(URLError(.networkConnectionLost)) }
            return .success((status: attempt == 2 ? 503 : 200, body: Data("done".utf8)))
        }
        defer { StubURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://transcription.example/upload")!)
        request.httpMethod = "POST"
        let (data, response) = try await TransientRequestRetry.upload(
            for: request, fromFile: bodyURL, session: session, engine: "Fixture"
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("done".utf8))
        XCTAssertEqual(attempts.withLock { $0 }, 3)
        XCTAssertEqual(TransientRequestRetry.backoffs, [1, 3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testTranscriptionRemovesUploadBodyOnSuccessAndHTTPFailure() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let original = try Data(contentsOf: audioURL)
        let directory = TemporaryAudioStorage.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for status in [200, 400] {
            let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            let observed = OSAllocatedUnfairLock(initialState: [URL]())
            await withLocalAIServerDefaults {
                StubURLProtocol.handler = { request in
                    if request.url?.path.hasSuffix("/health") == true {
                        return .success((status: 200, body: Data()))
                    }
                    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                    observed.withLock { $0 = files.filter { $0.pathExtension == "body" && !before.contains($0) } }
                    return .success((status: status, body: Data(#"{"text":"fixture result"}"#.utf8)))
                }
                do {
                    _ = try await makeStubbedTranscriber().transcribe(audioURL: audioURL, language: "es")
                    XCTAssertEqual(status, 200)
                } catch {
                    XCTAssertEqual(status, 400)
                    XCTAssertEqual((error as? TranscriptionFailure)?.kind, .clientError)
                }
            }
            let bodies = observed.withLock { $0 }
            XCTAssertEqual(bodies.count, 1)
            for body in bodies { XCTAssertFalse(FileManager.default.fileExists(atPath: body.path)) }
            XCTAssertEqual(try Data(contentsOf: audioURL), original)
        }
    }

    func testCancellationDuringUploadRetryRemovesBodyAndPreservesSource() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let original = try Data(contentsOf: audioURL)
        let directory = TemporaryAudioStorage.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
        let observed = OSAllocatedUnfairLock(initialState: [URL]())
        let upload = expectation(description: "Upload reached retryable response")
        await withLocalAIServerDefaults {
            StubURLProtocol.handler = { request in
                if request.url?.path.hasSuffix("/health") == true {
                    return .success((status: 200, body: Data()))
                }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                observed.withLock { $0 = files.filter { $0.pathExtension == "body" && !before.contains($0) } }
                upload.fulfill()
                return .success((status: 503, body: Data()))
            }
            let transcriber = makeStubbedTranscriber()
            let task = Task { try await transcriber.transcribe(audioURL: audioURL, language: "es") }
            await fulfillment(of: [upload], timeout: 3)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancelled upload must not succeed")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? TranscriptionFailure)?.kind == .userCancelled)
            }
        }
        let bodies = observed.withLock { $0 }
        XCTAssertEqual(bodies.count, 1)
        for body in bodies { XCTAssertFalse(FileManager.default.fileExists(atPath: body.path)) }
        XCTAssertEqual(try Data(contentsOf: audioURL), original)
    }

    // MARK: - Preflight reachability (fail fast when the server is down)

    /// URLProtocol stub: routes every request through a static handler so the
    /// tests can drive the preflight and upload responses independently.
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Result<(status: Int, body: Data), URLError>)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let handler = Self.handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            switch handler(request) {
            case .success(let response):
                let http = HTTPURLResponse(
                    url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.body)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func makeStubbedTranscriber() -> LocalAIServerTranscriber {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LocalAIServerTranscriber(session: URLSession(configuration: configuration))
    }

    /// Sets the UserDefaults config transcribe() reads, runs the body, and
    /// restores the previous values (the test host shares the defaults domain).
    private func withLocalAIServerDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = AppPreferences.defaults
        let previousURL = defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL)
        let previousModel = defaults.string(forKey: Constants.StorageKeys.localAIServerModel)
        defaults.set("http://127.0.0.1:9999", forKey: Constants.StorageKeys.localAIServerBaseURL)
        defaults.set("test-model", forKey: Constants.StorageKeys.localAIServerModel)
        defer {
            if let previousURL {
                defaults.set(previousURL, forKey: Constants.StorageKeys.localAIServerBaseURL)
            } else {
                defaults.removeObject(forKey: Constants.StorageKeys.localAIServerBaseURL)
            }
            if let previousModel {
                defaults.set(previousModel, forKey: Constants.StorageKeys.localAIServerModel)
            } else {
                defaults.removeObject(forKey: Constants.StorageKeys.localAIServerModel)
            }
            StubURLProtocol.handler = nil
        }
        try await body()
    }

    private func makeValidWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-ai-preflight-\(UUID().uuidString).wav")
        let sampleRate: UInt32 = 16_000
        let dataSize: UInt32 = sampleRate * 2  // 1 second, mono int16

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, 36 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)  // PCM
        appendUInt16(&data, 1)  // mono
        appendUInt32(&data, sampleRate)
        appendUInt32(&data, sampleRate * 2)
        appendUInt16(&data, 2)  // block align
        appendUInt16(&data, 16)  // bits per sample
        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
        return url
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    @MainActor
    func testTranscribeFailsFastWithNetworkErrorWhenServerUnreachable() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try await withLocalAIServerDefaults {
            StubURLProtocol.handler = { _ in .failure(URLError(.cannotConnectToHost)) }
            let transcriber = makeStubbedTranscriber()

            do {
                _ = try await transcriber.transcribe(audioURL: audioURL, language: "es")
                XCTFail("transcribe must throw when the server is unreachable")
            } catch let failure as TranscriptionFailure {
                XCTAssertEqual(failure.kind, .network)
                XCTAssertTrue(
                    failure.technicalDetail?.contains("preflight") == true,
                    "the failure must come from the preflight, not the upload timeout"
                )
            }
        }
    }

    @MainActor
    func testPreflightAcceptsAnyHTTPResponseAndUploadProceeds() async throws {
        let audioURL = try makeValidWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try await withLocalAIServerDefaults {
            // A 404 on /health (server without that endpoint) still proves
            // the host is alive; only transport failures may block the upload.
            StubURLProtocol.handler = { request in
                if request.url?.path.hasSuffix("/health") == true {
                    return .success((status: 404, body: Data()))
                }
                return .success((status: 200, body: Data(#"{"text": "hola mundo"}"#.utf8)))
            }
            let transcriber = makeStubbedTranscriber()

            let transcript = try await transcriber.transcribe(audioURL: audioURL, language: "es")
            XCTAssertEqual(transcript, "hola mundo")
        }
    }
}
