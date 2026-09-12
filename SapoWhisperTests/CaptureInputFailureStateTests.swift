import AudioToolbox
import XCTest

@testable import SapoWhisper

@MainActor
final class CaptureInputFailureStateTests: XCTestCase {
    func testStoppingNotificationsDoesNotLosePendingInputFailure() async throws {
        let capture = AudioCaptureEngine(mode: .batch)
        let token = capture.inputFailures.beginInput()
        let url = TemporaryAudioStorage.makeWAVURL(prefix: "input-failure-test")
        try Data([0]).write(to: url)
        capture.recordingURL = url
        capture.isRecording = true
        defer { capture.deleteRecording(at: url) }
        capture.invalidateSetupGeneration()
        capture.inputFailures.stopNotifying()
        capture.inputFailures.record(kAudioUnitErr_TooManyFramesToProcess, for: token)

        let result = await capture.stopRecordingAsync()

        XCTAssertFalse(capture.inputFailures.shouldNotify(for: token))
        XCTAssertEqual(result?.diagnostics.inputFailureCode, kAudioUnitErr_TooManyFramesToProcess)
        XCTAssertEqual(result?.diagnostics.integrityFailure?.kind, .recordingInterrupted)
        XCTAssertFalse(try XCTUnwrap(result).diagnostics.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRetiredInputCannotInterruptItsReplacement() {
        let failures = CaptureInputFailureState()
        let old = failures.beginInput()
        failures.stopNotifying()
        failures.record(kAudioUnitErr_CannotDoInCurrentContext, for: old)
        let replacement = failures.beginInput()

        XCTAssertFalse(failures.shouldNotify(for: old))
        XCTAssertTrue(failures.shouldNotify(for: replacement))
        XCTAssertEqual(failures.firstFailure, kAudioUnitErr_CannotDoInCurrentContext)
        failures.record(kAudioUnitErr_TooManyFramesToProcess, for: old)
        XCTAssertEqual(failures.firstFailure, kAudioUnitErr_CannotDoInCurrentContext)
    }

    func testStaleFailureCannotContaminateANewCapture() {
        let retired = CaptureInputFailureState()
        let token = retired.beginInput()
        let current = CaptureInputFailureState()
        let currentToken = current.beginInput()
        retired.record(kAudioUnitErr_CannotDoInCurrentContext, for: token)
        current.record(noErr, for: currentToken)
        XCTAssertNil(current.firstFailure)
        XCTAssertTrue(current.shouldNotify(for: currentToken))
    }
}
