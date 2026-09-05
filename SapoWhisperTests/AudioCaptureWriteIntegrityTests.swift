//
//  AudioCaptureWriteIntegrityTests.swift
//  SapoWhisperTests
//
//  Failed writes interrupt capture, preserve available PCM and cannot affect
//  a later recording.
//

import AVFoundation
import XCTest
import os

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
        XCTAssertEqual(
            diagnostics.firstWriteError,
            LogSanitizer.errorDiagnostic(StubWriteFailure.diskFull, state: "audio-write")
        )
        XCTAssertFalse(diagnostics.firstWriteError?.contains("stub-disk-full") == true)
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

    @MainActor
    func testDiskFailureReportsOnceAndKeepsWrittenAudio() async throws {
        let writes = OSAllocatedUnfairLock(initialState: 0)
        let reasons = OSAllocatedUnfairLock(initialState: [String]())
        let interrupted = expectation(description: "storage interruption")
        interrupted.assertForOverFulfill = true
        let engine = AudioCaptureEngine(mode: .batch) { buffer, file in
            let index = writes.withLock {
                $0 += 1
                return $0
            }
            if index == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            try file.write(from: buffer)
        }
        let url = TemporaryAudioStorage.makeWAVURL(prefix: "integrity-test")
        defer { engine.deleteRecording(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        engine.audioFile = writer
        engine.recordingURL = url
        engine.isRecording = true
        engine.onCaptureInterrupted = { reason in
            reasons.withLock { $0.append(reason) }
            interrupted.fulfill()
        }
        for index in 1...3 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            buffer.frameLength = 512
            buffer.floatChannelData?[0].initialize(repeating: Float(index) / 10, count: 512)
            _ = engine.registerInputBuffer(at: CFAbsoluteTimeGetCurrent())
            engine.writeConvertedBuffer(buffer, to: try XCTUnwrap(writer), publishLevel: false)
        }
        await fulfillment(of: [interrupted], timeout: 2)
        let stopped = await engine.stopRecordingAsync()
        let result = try XCTUnwrap(stopped)
        writer = nil

        XCTAssertEqual(reasons.withLock { $0 }, [AudioCaptureEngine.storageFailureReason])
        XCTAssertEqual(result.diagnostics.failedWriteCount, 1)
        XCTAssertEqual(result.diagnostics.integrityFailure?.kind, .audioStorageFailed)
        XCTAssertEqual(result.diagnostics.writtenFrameCount, 1024)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 1024)
    }

    @MainActor
    func testLateStorageFailureCannotInterruptANewerCapture() async throws {
        let engine = makeEngine()
        let reasons = OSAllocatedUnfairLock(initialState: [String]())
        engine.isRecording = true
        engine.onCaptureInterrupted = { reason in reasons.withLock { $0.append(reason) } }
        engine.registerWriteFailure(StubWriteFailure.diskFull)
        _ = engine.beginSetupGeneration()
        engine.resetCaptureDiagnostics(deviceUID: "next-input")
        await Task.yield()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(reasons.withLock { $0.isEmpty })
        XCTAssertNil(snapshot(engine).integrityFailure)
        engine.isRecording = false
    }
}
