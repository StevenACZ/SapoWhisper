//
//  AudioCaptureCoordinatorTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

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
            resumeMonitor: { resumeCount += 1 }
        )
        return (coordinator, { suspendCount }, { resumeCount })
    }

    func testBeginCaptureSuspendsMonitorAndMarksActive() {
        let (coordinator, suspendCalls, _) = makeCoordinator(monitorRunning: true)

        XCTAssertFalse(coordinator.isCaptureActive)
        coordinator.beginCapture(.batchRecorder)

        XCTAssertTrue(coordinator.isCaptureActive)
        XCTAssertEqual(coordinator.currentOwner, .batchRecorder)
        XCTAssertEqual(suspendCalls(), 1)
    }

    func testEndCaptureResumesMonitorOnlyWhenItWasSuspended() {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        coordinator.beginCapture(.fluxStreaming)
        coordinator.endCapture(.fluxStreaming)

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(resumeCalls(), 1)
    }

    func testEndCaptureDoesNotResumeWhenMonitorWasIdle() {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: false)

        coordinator.beginCapture(.batchRecorder)
        coordinator.endCapture(.batchRecorder)

        XCTAssertFalse(coordinator.isCaptureActive)
        XCTAssertEqual(resumeCalls(), 0)
    }

    func testStaleEndFromPreviousOwnerIsIgnored() {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        coordinator.beginCapture(.batchRecorder)
        // A stale cleanup from another path must not release the active capture.
        coordinator.endCapture(.fluxStreaming)

        XCTAssertTrue(coordinator.isCaptureActive)
        XCTAssertEqual(coordinator.currentOwner, .batchRecorder)
        XCTAssertEqual(resumeCalls(), 0)
    }

    func testEndActiveCaptureReleasesWhateverOwnerHoldsTheMic() {
        let (coordinator, _, resumeCalls) = makeCoordinator(monitorRunning: true)

        coordinator.beginCapture(.elevenLabsStreaming)
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

    func testMonitorIsSuspendedOnceAcrossNestedBegins() {
        let (coordinator, suspendCalls, resumeCalls) = makeCoordinator(monitorRunning: true)

        coordinator.beginCapture(.batchRecorder)
        coordinator.endCapture(.batchRecorder)
        coordinator.beginCapture(.fluxStreaming)
        coordinator.endCapture(.fluxStreaming)

        XCTAssertEqual(suspendCalls(), 2)
        XCTAssertEqual(resumeCalls(), 2)
    }
}
