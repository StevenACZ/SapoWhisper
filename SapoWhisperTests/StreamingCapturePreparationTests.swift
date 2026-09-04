import Combine
import XCTest

@testable import SapoWhisper

@MainActor
final class StreamingCapturePreparationTests: XCTestCase {
    private final class Session: StreamingDictationSession {
        var isStreaming = true
        var isPaused = false
        var recordingDuration: TimeInterval = 2
        var lastCaptureResult: AudioCaptureResult?
        var onCaptureInterrupted: ((String) -> Void)?
        var isStreamingPublisher: AnyPublisher<Bool, Never> { Just(isStreaming).eraseToAnyPublisher() }
        var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> { Just(recordingDuration).eraseToAnyPublisher() }
        var audioLevelPublisher: AnyPublisher<Float, Never> { Just(0).eraseToAnyPublisher() }
        var finalized = false
        var sealed = false

        func start(microphone: String, language: String) async throws {}
        func sealCapture() -> AudioCaptureResult? {
            sealed = true
            isStreaming = false
            return lastCaptureResult
        }
        func finalizeTranscription() async throws -> StreamingDictationResult {
            finalized = true
            throw CancellationError()
        }
        func cancel() {}
        func pauseRecording() {}
        func resumeRecording() throws {}
        func abortPreservingAudio() -> AudioCaptureResult? { lastCaptureResult }
    }

    func testHistoryExistsBeforeNetworkFinalizationAndKeepsTheFallbackSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        try Data(repeating: 0, count: 4096).write(to: source)
        let manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: directory.appendingPathComponent("history"))
        let persister = DictationHistoryPersister(historyManager: manager) { try? FileManager.default.removeItem(at: $0) }
        let session = Session()
        session.lastCaptureResult = AudioCaptureResult(
            audioURL: source, duration: 2,
            diagnostics: RecordingCaptureDiagnostics(
                selectedDeviceUID: "fixture", inputBufferCount: 2, writtenFrameCount: 1024,
                emittedChunkCount: 2, firstInputLatencyMs: 1, lastBufferAgeMs: 0, maxInputGapMs: 0, fileSizeBytes: 4096
            )
        )
        var acknowledgedAfterSeal = false
        let prepared = StreamingCapturePreparation.prepare(
            session: session, persister: persister, variant: .deepgramFluxLive,
            engineName: "Deepgram Flux", language: "en",
            onStopped: { acknowledgedAfterSeal = session.sealed }
        )
        let pending = try XCTUnwrap(prepared.pending)
        XCTAssertTrue(acknowledgedAfterSeal)
        XCTAssertFalse(session.finalized)
        XCTAssertEqual(manager.fetchAll().map(\.id), [pending.historyId])
        XCTAssertEqual(manager.fetchAll().first?.status, "transcribing")
        XCTAssertEqual(prepared.historyTarget, .finalizePending(historyId: pending.historyId))
        XCTAssertNotEqual(pending.audioURL, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        persister.finishPreservedSource(source, pending: pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.audioURL.path))
    }
}
