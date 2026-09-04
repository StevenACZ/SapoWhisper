//
//  AudioCaptureCoordinatorTests.swift
//  SapoWhisperTests
//

import XCTest
import os

@testable import SapoWhisper

@MainActor
final class AudioCaptureCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        monitorRunning: Bool
    ) -> (coordinator: AudioCaptureCoordinator, suspendCalls: () -> Int, resumeCalls: () -> Int) {
        var suspendCount = 0
        var resumeCount = 0
        let coordinator = AudioCaptureCoordinator(
            suspendMonitor: {
                suspendCount += 1
                return monitorRunning
            },
            resumeMonitor: { resumeCount += 1 },
            activityGate: AudioInputActivityGate()
        )
        return (coordinator, { suspendCount }, { resumeCount })
    }

    func testBeginCaptureSuspendsMonitorAndMarksActive() async throws {
        let (coordinator, suspendCalls, _) = makeCoordinator(monitorRunning: true)

        XCTAssertFalse(coordinator.isCaptureActive)
        let token = try await coordinator.beginCapture(.batchRecorder)

        XCTAssertNotNil(token)
        XCTAssertTrue(coordinator.isCaptureActive)
        XCTAssertEqual(coordinator.currentOwner, .batchRecorder)
        XCTAssertEqual(suspendCalls(), 1)
    }

    func testEndCaptureResumesMonitorOnlyWhenItWasSuspended() async throws {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        guard let token = try await coordinator.beginCapture(.fluxStreaming) else { return XCTFail("capture not acquired") }
        coordinator.endCapture(token)

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(resumeCalls(), 1)
    }

    func testEndCaptureDoesNotResumeWhenMonitorWasIdle() async throws {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: false)

        guard let token = try await coordinator.beginCapture(.batchRecorder) else { return XCTFail("capture not acquired") }
        coordinator.endCapture(token)

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(resumeCalls(), 0)
    }

    func testStaleEndFromPreviousOwnerIsIgnored() async throws {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        guard let staleToken = try await coordinator.beginCapture(.batchRecorder) else {
            return XCTFail("first capture not acquired")
        }
        coordinator.endActiveCapture()
        guard let currentToken = try await coordinator.beginCapture(.batchRecorder) else {
            return XCTFail("second capture not acquired")
        }
        coordinator.endCapture(staleToken)

        XCTAssertTrue(coordinator.isCaptureActive)
        XCTAssertEqual(coordinator.currentOwner, .batchRecorder)
        XCTAssertEqual(resumeCalls(), 1)
        coordinator.endCapture(currentToken)
    }

    func testEndActiveCaptureReleasesWhateverOwnerHoldsTheMic() async throws {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        _ = try await coordinator.beginCapture(.elevenLabsStreaming)
        coordinator.endActiveCapture()

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertNil(coordinator.currentOwner)
        XCTAssertEqual(resumeCalls(), 1)
    }

    func testEndActiveCaptureWithoutCaptureIsNoOp() {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        coordinator.endActiveCapture()

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(resumeCalls(), 0)
    }

    func testMonitorIsSuspendedOnceAcrossNestedBegins() async throws {
        let (coordinator, suspendCalls, resumeCalls) = makeCoordinator(monitorRunning: true)

        guard let batchToken = try await coordinator.beginCapture(.batchRecorder) else {
            return XCTFail("batch capture not acquired")
        }
        coordinator.endCapture(batchToken)
        guard let fluxToken = try await coordinator.beginCapture(.fluxStreaming) else {
            return XCTFail("streaming capture not acquired")
        }
        coordinator.endCapture(fluxToken)

        XCTAssertEqual(suspendCalls(), 2)
        XCTAssertEqual(resumeCalls(), 2)
    }

    func testCaptureGateRejectsPreflightUntilCaptureEnds() async throws {
        let gate = AudioInputActivityGate()

        let firstLease = try await gate.beginCapture()
        XCTAssertFalse(gate.beginPreflightIfIdle())
        gate.endCapture(firstLease)

        XCTAssertTrue(gate.beginPreflightIfIdle())
        gate.endPreflight()

        XCTAssertTrue(gate.beginMonitorIfIdle())
        XCTAssertFalse(gate.beginPreflightIfIdle())
        gate.endMonitor()

        let secondLease = try await gate.beginCapture()
        XCTAssertFalse(gate.beginMonitorIfIdle())
        gate.endCapture(secondLease)
    }

    func testCaptureWaitsUntilAnActivePreflightFinishes() async throws {
        let gate = AudioInputActivityGate()
        XCTAssertTrue(gate.beginPreflightIfIdle())
        let captureReturned = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let lease = try await gate.beginCapture()
            captureReturned.withLock { $0 = true }
            return lease
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(captureReturned.withLock { $0 })
        gate.endPreflight()
        let lease = try await task.value
        XCTAssertTrue(captureReturned.withLock { $0 })
        gate.endCapture(lease)
    }

    func testCancelledWaitCannotReviveOrReleaseANewerCapture() async throws {
        let gate = AudioInputActivityGate()
        XCTAssertTrue(gate.beginPreflightIfIdle())
        var suspendCount = 0
        let coordinator = AudioCaptureCoordinator(
            suspendMonitor: {
                suspendCount += 1
                return false
            },
            resumeMonitor: {},
            activityGate: gate
        )

        let cancelledStart = Task { try await coordinator.beginCapture(.batchRecorder) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancelledStart.cancel()
        coordinator.endActiveCapture()
        do {
            let cancelledToken = try await cancelledStart.value
            XCTAssertNil(cancelledToken)
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        gate.endPreflight()
        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(suspendCount, 0)

        guard let currentToken = try await coordinator.beginCapture(.batchRecorder) else {
            return XCTFail("replacement capture not acquired")
        }
        XCTAssertTrue(coordinator.isCaptureActive)
        coordinator.endCapture(currentToken)
    }
    func testBlockedPreflightHasABoundedCaptureWait() async throws {
        let gate = AudioInputActivityGate(captureWaitTimeout: .milliseconds(30))
        XCTAssertTrue(gate.beginPreflightIfIdle())
        let started = ContinuousClock.now
        do {
            _ = try await gate.beginCapture()
            XCTFail("Expected input setup timeout")
        } catch RecordingError.inputSetupTimedOut {
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        }
        XCTAssertFalse(gate.beginPreflightIfIdle())
        gate.endPreflight()
        let lease = try await gate.beginCapture()
        gate.endCapture(lease)
        XCTAssertTrue(gate.beginPreflightIfIdle())
        gate.endPreflight()
    }

}
