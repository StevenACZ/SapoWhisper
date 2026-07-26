//
//  AudioCaptureWriteIntegrityTests.swift
//  SapoWhisperTests
//
//  HSW-046: a failed disk write must reach the stop-path diagnostics, so a
//  truncated WAV is never handed back as a clean take (it is also the backup a
//  failed transcription is rescued from).
//

import AVFoundation
import XCTest

@testable import SapoWhisper

final class AudioCaptureWriteIntegrityTests: XCTestCase {

    private enum StubWriteFailure: LocalizedError {
        case diskFull
        case ioError

        var errorDescription: String? {
            switch self {
            case .diskFull: return "stub-disk-full"
            case .ioError: return "stub-io-error"
            }
        }
    }

    private func makeEngine() -> AudioCaptureEngine {
        let engine = AudioCaptureEngine(mode: .batch)
        engine.resetCaptureDiagnostics(deviceUID: "test-input")
        return engine
    }

    private func snapshot(_ engine: AudioCaptureEngine) -> RecordingCaptureDiagnostics {
        engine.makeCaptureDiagnostics(fileURL: nil, referenceTime: CFAbsoluteTimeGetCurrent())
    }

    func testCaptureWithoutWriteFailuresIsComplete() {
        let diagnostics = snapshot(makeEngine())

        XCTAssertTrue(diagnostics.isComplete)
        XCTAssertEqual(diagnostics.failedWriteCount, 0)
        XCTAssertNil(diagnostics.firstWriteError)
    }

    func testFailedWritesAreCountedAndKeepTheFirstError() {
        let engine = makeEngine()

        engine.registerWriteFailure(StubWriteFailure.diskFull)
        engine.registerWriteFailure(StubWriteFailure.ioError)

        let diagnostics = snapshot(engine)
        XCTAssertFalse(diagnostics.isComplete)
        XCTAssertEqual(diagnostics.failedWriteCount, 2)
        XCTAssertEqual(diagnostics.firstWriteError, "stub-disk-full")
    }

    func testTruncatedCaptureStillReportsTheInputItDidReceive() {
        let engine = makeEngine()

        _ = engine.registerInputBuffer(at: CFAbsoluteTimeGetCurrent())
        engine.registerWrittenFrames(512)
        engine.registerWriteFailure(StubWriteFailure.diskFull)

        let diagnostics = snapshot(engine)
        XCTAssertTrue(diagnostics.receivedInput)
        XCTAssertFalse(diagnostics.isComplete)
    }

    func testWriteFailuresDoNotLeakIntoTheNextRecording() {
        let engine = makeEngine()
        engine.registerWriteFailure(StubWriteFailure.diskFull)

        engine.resetCaptureDiagnostics(deviceUID: "test-input")

        let diagnostics = snapshot(engine)
        XCTAssertTrue(diagnostics.isComplete)
        XCTAssertEqual(diagnostics.failedWriteCount, 0)
        XCTAssertNil(diagnostics.firstWriteError)
    }
}
