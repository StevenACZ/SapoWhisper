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
private nonisolated final class RecorderFake: CaptureStarting, @unchecked Sendable {
    var selectedDeviceUID = "default"

    /// Consumed once per `startRecording` call; nil / exhausted = success.
    var startErrors: [Error] = []
    /// Consumed once per `waitForFirstInputBuffer` call; exhausted = false.
    var waitResults: [Bool] = []
    var waitSuspendsUntilCancelled = false
    var firstStartDelay: TimeInterval = 0
    var prepareDelay: TimeInterval = 0
    var onStart: (() -> Void)?
    var onWait: (() -> Void)?
    var onDiscard: (() -> Void)?
    var emitChunk = false
    private(set) var selectedUIDs: [String] = []

    private(set) var startCallCount = 0
    private(set) var startedEngines: [TranscriptionEngine?] = []
    private(set) var waitTimeouts: [TimeInterval] = []
    private(set) var discardCount = 0

    func prepareInputDeviceForRecording() -> TimeInterval { prepareDelay }

    func startRecording(targetEngine: TranscriptionEngine?, onPCMChunk: AudioCaptureEngine.PCMChunkHandler?) async throws {
        startCallCount += 1
        startedEngines.append(targetEngine)
        selectedUIDs.append(selectedDeviceUID)
        onStart?()
        if startCallCount == 1, firstStartDelay > 0 {
            try await Task.sleep(for: .seconds(firstStartDelay))
        }
        if !startErrors.isEmpty {
            throw startErrors.removeFirst()
        }
        if emitChunk { onPCMChunk?(Data([1, 2])) }
    }

    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool {
        waitTimeouts.append(timeout)
        onWait?()
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
        onDiscard?()
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

    func testSlowFirstAttemptStillReceivesRecoveryAttempt() async throws {
        let recorder = RecorderFake()
        recorder.firstStartDelay = 1.1
        recorder.startErrors = [RecordingError.invalidFormat]
        recorder.waitResults = [true]
        let supervisor = makeSupervisor(recorder: recorder)

        try await supervisor.start(microphone: "preferred-mic", targetEngine: .localAIServer)

        XCTAssertEqual(recorder.startCallCount, 2)
        XCTAssertEqual(recorder.discardCount, 1)
        XCTAssertEqual(recorder.selectedDeviceUID, "preferred-mic")
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
        XCTAssertEqual(slept, [0.15, 0.30])
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
        XCTAssertEqual(slept, [0.15, 0.30], "each retry sleeps only once")
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

    func testTransientlyMissingPreferredInputRetriesOnlyTheSameUID() async throws {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.inputDeviceUnavailable]
        recorder.waitResults = [true]
        var routeDelay: TimeInterval = 0.1
        let supervisor = CaptureStartSupervisor(
            recorder: recorder, transport: { _ in .usb },
            routeSettleDelay: { routeDelay }, sleep: { _ in routeDelay = 0 }
        )

        try await supervisor.start(microphone: "preferred-mic", targetEngine: .localAIServer)

        XCTAssertEqual(recorder.selectedUIDs, ["preferred-mic", "preferred-mic"])
        XCTAssertEqual(recorder.discardCount, 1)
    }

    func testRecoveryBudgetBoundsRepeatedSlowFailures() async {
        let recorder = RecorderFake()
        recorder.startErrors = Array(repeating: RecordingError.invalidFormat, count: 3)
        var time: TimeInterval = 0
        recorder.onStart = { time += 2 }
        let supervisor = CaptureStartSupervisor(
            recorder: recorder, transport: { _ in .usb }, routeSettleDelay: { 0 },
            now: { time }, sleep: { time += $0 }
        )

        do {
            try await supervisor.start(microphone: "preferred-mic")
            XCTFail("expected invalidFormat")
        } catch {
            XCTAssertEqual(recorder.startCallCount, 2)
            XCTAssertEqual(recorder.discardCount, 2)
        }
    }

    func testRouteSettleAndRetryBackoffShareOneWait() async throws {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.invalidFormat]
        recorder.waitResults = [true]
        recorder.onDiscard = { recorder.prepareDelay = 0.35 }
        var sleeps: [TimeInterval] = []
        let supervisor = makeSupervisor(recorder: recorder) { sleeps.append($0) }

        try await supervisor.start(microphone: "preferred-mic")

        XCTAssertEqual(sleeps, [0.35])
    }

    func testStreamingUsesSharedRecoveryAndPreservesChunkHandler() async throws {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.invalidFormat]
        recorder.waitResults = [true]
        recorder.emitChunk = true
        var chunks: [Data] = []
        var sleeps: [TimeInterval] = []
        let supervisor = CaptureStartSupervisor(
            recorder: recorder, mode: .streaming, transport: { _ in .usb },
            routeSettleDelay: { 0 }, sleep: { sleeps.append($0) }
        )

        try await supervisor.start(microphone: "preferred-mic") { chunks.append($0) }

        XCTAssertEqual(chunks, [Data([1, 2])])
        XCTAssertEqual(sleeps, [0.25])
        XCTAssertEqual(recorder.waitTimeouts, [1.2])
        XCTAssertEqual(recorder.selectedUIDs, ["preferred-mic", "preferred-mic"])
    }

    func testStreamingBluetoothUsesExtendedFirstBufferWindow() async throws {
        let recorder = RecorderFake()
        recorder.waitResults = [true]
        let supervisor = CaptureStartSupervisor(
            recorder: recorder, mode: .streaming, transport: { _ in .bluetooth },
            routeSettleDelay: { 0 }, sleep: { _ in }
        )

        try await supervisor.start(microphone: "preferred-mic")

        XCTAssertEqual(recorder.waitTimeouts, [2.5])
    }

    func testPermissionFailureNeverRetriesDuringRouteChurn() async {
        let recorder = RecorderFake()
        recorder.startErrors = [RecordingError.permissionDenied]
        let supervisor = CaptureStartSupervisor(
            recorder: recorder, transport: { _ in .usb },
            routeSettleDelay: { 0.1 }, sleep: { _ in }
        )

        do {
            try await supervisor.start(microphone: "preferred-mic")
            XCTFail("expected permission failure")
        } catch {
            XCTAssertEqual(recorder.startCallCount, 1)
            XCTAssertEqual(recorder.discardCount, 1)
        }
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
