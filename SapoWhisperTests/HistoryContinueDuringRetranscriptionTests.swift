import AVFoundation
import XCTest

@testable import SapoWhisper

@MainActor
final class HistoryContinueDuringRetranscriptionTests: XCTestCase {
    private final class SuspendedProcessor: TranscriptPostProcessing {
        let entered: XCTestExpectation
        private(set) var continuation: CheckedContinuation<Void, Never>?

        init(entered: XCTestExpectation) {
            self.entered = entered
        }

        func willAttemptPolish(rawText: String, duration: TimeInterval?, enforceMinimumDuration: Bool) -> Bool {
            true
        }

        func process(
            rawText: String, duration: TimeInterval?, provider: PolishProviderConfiguration?, enforceMinimumDuration: Bool
        ) async -> TranscriptAIResult {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
            return TranscriptAIResult(
                rawText: rawText, finalText: rawText, status: .none, model: nil,
                mode: nil, error: nil, elapsedMs: 0
            )
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private final class FixtureProvider: URLProtocol {
        nonisolated static let host = "continue-history-fixture.invalid"

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == host
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let data = url.path.hasSuffix("/health") ? Data() : Data(#"{"text":"Synthetic history fixture."}"#.utf8)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func testSameFailedRowCannotContinueWhileRetranscriptionIsSuspendedInPolish() async throws {
        try XCTSkipUnless(AppRuntimePaths.isIsolated, "Requires isolated test preferences and History")
        let defaults = AppPreferences.defaults
        let configuredValues = [
            Constants.StorageKeys.transcriptionEngine: TranscriptionEngine.localAIServer.rawValue,
            Constants.StorageKeys.fallbackTranscriptionEngine: "",
            Constants.StorageKeys.localAIServerBaseURL: "https://\(FixtureProvider.host)",
            Constants.StorageKeys.localAIServerModel: "fixture-model",
        ]
        let previous = configuredValues.keys.map { ($0, defaults.object(forKey: $0)) }
        for (key, value) in configuredValues { defaults.set(value, forKey: key) }
        defer {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        XCTAssertTrue(URLProtocol.registerClass(FixtureProvider.self))
        defer { URLProtocol.unregisterClass(FixtureProvider.self) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-continue-polish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstAudio = directory.appendingPathComponent("first.wav")
        let secondAudio = directory.appendingPathComponent("second.wav")
        try writeAudio(to: firstAudio)
        try writeAudio(to: secondAudio)
        let manager = TranscriptionHistoryManager.shared
        let firstID = manager.save(
            engine: "Fixture", language: "es", duration: 1, text: "", audioPath: firstAudio.path,
            status: HistoryEntryStatus.failed.rawValue, failureCode: "Fixture/user_cancelled"
        )
        let secondID = manager.save(
            engine: "Fixture", language: "es", duration: 1, text: "", audioPath: secondAudio.path,
            status: HistoryEntryStatus.failed.rawValue, failureCode: "Fixture/user_cancelled"
        )
        defer {
            manager.delete(id: firstID)
            manager.delete(id: secondID)
        }
        let first = try XCTUnwrap(manager.entry(id: firstID))
        let second = try XCTUnwrap(manager.entry(id: secondID))
        let entered = expectation(description: "History retranscription reached suspended polish")
        let processor = SuspendedProcessor(entered: entered)
        let viewModel = SapoWhisperViewModel(transcriptPostProcessor: processor)
        XCTAssertTrue(viewModel.canContinueHistoryEntry(first))
        XCTAssertTrue(viewModel.canContinueHistoryEntry(second))

        let retranscription = Task {
            await viewModel.retranscribeHistoryEntry(first, using: .localAIServer)
        }
        await fulfillment(of: [entered], timeout: 5)
        if processor.continuation != nil {
            XCTAssertEqual(manager.entry(id: firstID)?.status, HistoryEntryStatus.failed.rawValue)
            XCTAssertFalse(viewModel.localAIServerTranscriber.isTranscribing)
            XCTAssertTrue(viewModel.canRecord)
            XCTAssertTrue(viewModel.canContinueHistoryEntry(second))
            XCTAssertFalse(viewModel.canContinueHistoryEntry(first))
        } else {
            XCTFail("The suspended polish phase is required to exercise the per-row guard")
        }

        retranscription.cancel()
        processor.resume()
        let result = await retranscription.value
        XCTAssertNil(result.errorMessage)
        let preserved = try XCTUnwrap(manager.entry(id: firstID))
        XCTAssertEqual(preserved.status, HistoryEntryStatus.failed.rawValue)
        XCTAssertTrue(preserved.audioFileExists)
        XCTAssertTrue(viewModel.canContinueHistoryEntry(preserved))
    }

    private func writeAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.int16ChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) { channel[frame] = 100 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        try file.write(from: buffer)
    }
}
