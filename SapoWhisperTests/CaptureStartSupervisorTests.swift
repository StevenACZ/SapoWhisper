//
//  CaptureStartSupervisorTests.swift
//  SapoWhisperTests
//
//  Start-with-recovery control flow: first-buffer gate, Bluetooth's extended
//  timeouts, transient-failure retries with backoff, and cancellation
//  passthrough — all through a fake recorder, no AVAudioEngine.
//

import XCTest

@testable import SapoWhisper

/// Driven exclusively from the supervisor (MainActor), so plain vars are safe.
private nonisolated final class RecorderFake: BatchCaptureStarting, @unchecked Sendable {
    var selectedDeviceUID = "default"

    /// Consumed once per `startRecording` call; nil / exhausted = success.
    var startErrors: [Error] = []
    /// Consumed once per `waitForFirstInputBuffer` call; exhausted = false.
    var waitResults: [Bool] = []
    var waitSuspendsUntilCancelled = false

    private(set) var startCallCount = 0
    private(set) var startedEngines: [TranscriptionEngine?] = []
    private(set) var waitTimeouts: [TimeInterval] = []
    private(set) var discardCount = 0

    func prepareInputDeviceForRecording() -> TimeInterval { 0 }

    func startRecording(targetEngine: TranscriptionEngine?, onPCMChunk: AudioCaptureEngine.PCMChunkHandler?) async throws {
        startCallCount += 1
        startedEngines.append(targetEngine)
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
    }

    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool {
        waitTimeouts.append(timeout)
        if waitSuspendsUntilCancelled {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }
        guard !waitResults.isEmpty else { return false }
        return waitResults.removeFirst()
    }

    func currentCaptureDiagnostics() -> RecordingCaptureDiagnostics {
        RecordingCaptureDiagnostics(
            selectedDeviceUID: selectedDeviceUID,
            inputBufferCount: 0,
            writtenFrameCount: 0,
            emittedChunkCount: 0,
            firstInputLatencyMs: nil,
            lastBufferAgeMs: nil,
            maxInputGapMs: 0,
            fileSizeBytes: 0
        )
    }

    func discardRecording() {
        discardCount += 1
    }
}

@MainActor
final class CaptureStartSupervisorTests: XCTestCase {

    private func makeSupervisor(
        recorder: RecorderFake,
        transport: AudioDeviceTransport = .builtIn,
        onSleep: @escaping (TimeInterval) -> Void = { _ in }
    ) -> CaptureStartSupervisor {
        CaptureStartSupervisor(
            recorder: recorder,
            transport: { _ in transport },
            routeSettleDelay: { 0 },
            sleep: { onSleep($0) }
        )
    }

    func testHappyPathStartsOnFirstAttempt() async throws {
        let recorder = RecorderFake()
        recorder.waitResults = [true]
        var slept: [TimeInterval] = []
        let supervisor = makeSupervisor(recorder: recorder) { slept.append($0) }

        try await supervisor.start(microphone: "mic-uid", targetEngine: .mlxWhisper)

        XCTAssertEqual(recorder.startCallCount, 1)
        XCTAssertEqual(recorder.selectedDeviceUID, "mic-uid")
        XCTAssertEqual(recorder.startedEngines, [.mlxWhisper])
        XCTAssertEqual(recorder.waitTimeouts, [0.8], "non-Bluetooth inputs keep the default first-buffer timeout")
        XCTAssertEqual(recorder.discardCount, 0)
        XCTAssertTrue(slept.isEmpty)
    }

    func testBluetoothInputUsesExtendedTimeoutAndRetryBudget() async {
        let recorder = RecorderFake()  // wait never sees input
        var slept: [TimeInterval] = []
        let supervisor = makeSupervisor(recorder: recorder, transport: .bluetooth) { slept.append($0) }

        do {
            try await supervisor.start(microphone: "airpods", targetEngine: .deepgram)
            XCTFail("expected noInputAfterDeviceSwitch")
        } catch let error as RecordingError {
            guard case .noInputAfterDeviceSwitch = error else {
                return XCTFail("unexpected recording error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.startCallCount, 3, "the 5 s Bluetooth budget allows all three attempts")
        XCTAssertEqual(recorder.waitTimeouts, [2.5, 2.5, 2.5], "Bluetooth widens the first-buffer window")
        XCTAssertEqual(recorder.discardCount, 3)
        // Backoff sleeps between attempts, each followed by the same value as
        // the next attempt's minimum settle delay.
        XCTAssertEqual(slept, [0.15, 0.15, 0.30, 0.30])
    }

    func testRecoverableStartErrorRetriesWithBackoff() async throws {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.invalidFormat, RecordingError.invalidFormat]
        recorder.waitResults = [true]
        var slept: [TimeInterval] = []
        let supervisor = makeSupervisor(recorder: recorder) { slept.append($0) }

        try await supervisor.start(microphone: "default", targetEngine: .mlxWhisper)

        XCTAssertEqual(recorder.startCallCount, 3)
        XCTAssertEqual(recorder.discardCount, 2, "each failed attempt discards its partial recording")
        XCTAssertEqual(recorder.waitTimeouts, [0.8], "only the successful attempt reaches the input wait")
        XCTAssertEqual(slept, [0.15, 0.15, 0.30, 0.30], "backoff schedule 0.15/0.30 plus matching settle floors")
    }

    func testUnavailablePreferredInputFailsWithoutRetrying() async {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.inputDeviceUnavailable]
        let supervisor = makeSupervisor(recorder: recorder)

        do {
            try await supervisor.start(microphone: "missing-mic", targetEngine: .mlxWhisper)
            XCTFail("expected inputDeviceUnavailable")
        } catch let error as RecordingError {
            guard case .inputDeviceUnavailable = error else {
                return XCTFail("unexpected recording error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.startCallCount, 1)
        XCTAssertEqual(recorder.discardCount, 1)
    }

    func testInputSetupTimeoutFailsWithoutRetrying() async {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.inputSetupTimedOut]
        let supervisor = makeSupervisor(recorder: recorder)

        do {
            try await supervisor.start(microphone: "mic-uid", targetEngine: .mlxWhisper)
            XCTFail("expected inputSetupTimedOut")
        } catch let error as RecordingError {
            guard case .inputSetupTimedOut = error else {
                return XCTFail("unexpected recording error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.startCallCount, 1)
        XCTAssertEqual(recorder.discardCount, 1)
    }

    func testCancellationAbortsWithoutSideEffects() async {
        let recorder = RecorderFake()
        recorder.waitSuspendsUntilCancelled = true
        let supervisor = makeSupervisor(recorder: recorder)

        let task = Task { try await supervisor.start(microphone: "default", targetEngine: .mlxWhisper) }

        // Let the supervisor reach the first-buffer wait before cancelling.
        for _ in 0..<200 where recorder.waitTimeouts.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(recorder.waitTimeouts.isEmpty, "supervisor never reached the input wait")
        task.cancel()

        do {
            try await task.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.startCallCount, 1, "cancellation must not start another attempt")
    }
}
