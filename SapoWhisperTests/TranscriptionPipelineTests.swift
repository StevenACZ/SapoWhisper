//
//  TranscriptionPipelineTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

/// C4: control-flow coverage for the shared transcribe→polish→paste→persist
/// pipeline — stage order, the staleness gate before every stage (C2), and
/// the local-silence rule that skips failed history rows.
@MainActor
final class TranscriptionPipelineTests: XCTestCase {

    private final class HostSpy: TranscriptionPipelineHost {
        var sessionLooksSilent = false
        var currentSessionID: UInt64? = 7
        var becomesStaleDuringPolish = false

        var polishedTranscripts: [(rawText: String, source: String, duration: TimeInterval?)] = []
        var deliveredTexts: [String] = []
        var presentedFailures: [TranscriptionFailure] = []
        var completedPersists: [(audioURL: URL, engineName: String, language: String, finalText: String)] = []
        var failedPersists: [(audioURL: URL, engineName: String, language: String, failureCode: String)] = []
        var staleCleanups: [(audioURL: URL, sessionID: UInt64)] = []
        var clearedSessionCount = 0
        var snapshotReasons: [String] = []

        func isTranscriptionSessionCurrent(_ sessionID: UInt64) -> Bool {
            currentSessionID == sessionID
        }

        func clearActiveTranscriptionSession() {
            clearedSessionCount += 1
            currentSessionID = nil
        }

        func handleStaleTranscriptionCompletion(audioURL: URL, sessionID: UInt64) {
            staleCleanups.append((audioURL, sessionID))
        }

        func postProcessTranscript(
            _ rawText: String, source: String, duration: TimeInterval?
        ) async -> TranscriptAIResult {
            polishedTranscripts.append((rawText, source, duration))
            if becomesStaleDuringPolish {
                currentSessionID = nil
            }
            return TranscriptAIResult(
                rawText: rawText,
                finalText: "polished " + rawText,
                status: .applied,
                model: "test-model",
                mode: "automatic",
                error: nil,
                elapsedMs: 1
            )
        }

        func deliverTranscription(_ finalText: String, perf: DictationPerfTimeline?) {
            deliveredTexts.append(finalText)
        }

        func presentTranscriptionFailure(_ failure: TranscriptionFailure) {
            presentedFailures.append(failure)
        }

        func persistCompletedDictation(
            audioURL: URL,
            engine: TranscriptionEngine,
            engineName: String,
            language: String,
            duration: TimeInterval,
            aiResult: TranscriptAIResult,
            perf: DictationPerfTimeline?
        ) {
            completedPersists.append((audioURL, engineName, language, aiResult.finalText))
        }

        func persistFailedDictation(
            audioURL: URL,
            engine: TranscriptionEngine,
            engineName: String,
            language: String,
            duration: TimeInterval,
            failure: TranscriptionFailure
        ) {
            failedPersists.append((audioURL, engineName, language, failure.diagnosticCode))
        }

        func logTranscriptionSnapshot(reason: String, extra: String) {
            snapshotReasons.append(reason)
        }
    }

    private let audioURL = URL(fileURLWithPath: "/tmp/pipeline-test.wav")

    private func makeRequest(sessionID: UInt64 = 7) -> TranscriptionPipeline.Request {
        TranscriptionPipeline.Request(
            sessionID: sessionID,
            engine: .deepgram,
            engineName: "Deepgram Flux",
            source: "flux",
            failureLanguage: "auto",
            snapshotPrefix: "flux-transcription",
            logger: SapoLog.flux,
            perf: nil
        )
    }

    private func makeOutput(transcript: String = "hola mundo desde el test") -> TranscriptionPipeline.EngineOutput {
        TranscriptionPipeline.EngineOutput(
            transcript: transcript,
            audioURL: audioURL,
            duration: 4.2,
            language: "es"
        )
    }

    // MARK: - Happy path

    func testHappyPathPolishesDeliversAndPersistsCompleted() async {
        let host = HostSpy()
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            self.makeOutput()
        } captureResultOnFailure: {
            XCTFail("captureResultOnFailure must not run on success")
            return nil
        }

        XCTAssertEqual(host.polishedTranscripts.count, 1)
        XCTAssertEqual(host.polishedTranscripts.first?.rawText, "hola mundo desde el test")
        XCTAssertEqual(host.polishedTranscripts.first?.source, "flux")
        XCTAssertEqual(host.polishedTranscripts.first?.duration, 4.2)

        XCTAssertEqual(host.deliveredTexts, ["polished hola mundo desde el test"])
        XCTAssertEqual(host.clearedSessionCount, 1)

        XCTAssertEqual(host.completedPersists.count, 1)
        XCTAssertEqual(host.completedPersists.first?.language, "es")
        XCTAssertEqual(host.completedPersists.first?.engineName, "Deepgram Flux")
        XCTAssertEqual(host.completedPersists.first?.audioURL, audioURL)

        XCTAssertTrue(host.presentedFailures.isEmpty)
        XCTAssertTrue(host.failedPersists.isEmpty)
        XCTAssertTrue(host.staleCleanups.isEmpty)
        XCTAssertEqual(host.snapshotReasons, ["flux-transcription-completed"])
    }

    // MARK: - Engine failures

    func testEngineFailurePresentsFailureAndPersistsFailedRow() async {
        let host = HostSpy()
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            throw TranscriptionFailure(kind: .network, engine: "Deepgram")
        } captureResultOnFailure: {
            (self.audioURL, 3.0)
        }

        XCTAssertEqual(host.presentedFailures.count, 1)
        XCTAssertEqual(host.presentedFailures.first?.kind, .network)
        XCTAssertEqual(host.clearedSessionCount, 1)

        XCTAssertEqual(host.failedPersists.count, 1)
        XCTAssertEqual(host.failedPersists.first?.language, "auto")
        XCTAssertEqual(host.failedPersists.first?.failureCode, "Deepgram/network")

        XCTAssertTrue(host.deliveredTexts.isEmpty)
        XCTAssertTrue(host.polishedTranscripts.isEmpty)
        XCTAssertTrue(host.completedPersists.isEmpty)
        XCTAssertEqual(host.snapshotReasons, ["flux-transcription-failed"])
    }

    func testEngineFailureWithoutCaptureResultSkipsFailedRow() async {
        let host = HostSpy()
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            throw TranscriptionFailure(kind: .serverError, engine: "Deepgram")
        } captureResultOnFailure: {
            nil
        }

        XCTAssertEqual(host.presentedFailures.count, 1)
        XCTAssertTrue(host.failedPersists.isEmpty)
        XCTAssertTrue(host.staleCleanups.isEmpty)
    }

    // MARK: - Local-silence rule

    func testSilentEmptyTranscriptionSkipsFailedRowButPresentsFailure() async {
        let host = HostSpy()
        host.sessionLooksSilent = true
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            throw TranscriptionFailure(kind: .emptyTranscription, engine: "Deepgram")
        } captureResultOnFailure: {
            (self.audioURL, 3.0)
        }

        XCTAssertEqual(host.presentedFailures.count, 1)
        XCTAssertEqual(host.presentedFailures.first?.kind, .emptyTranscription)
        XCTAssertTrue(host.failedPersists.isEmpty, "silence sessions must not create failed history rows")
    }

    func testSilentSessionStillPersistsNonEmptyFailures() async {
        let host = HostSpy()
        host.sessionLooksSilent = true
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            throw TranscriptionFailure(kind: .network, engine: "Deepgram")
        } captureResultOnFailure: {
            (self.audioURL, 3.0)
        }

        XCTAssertEqual(host.failedPersists.count, 1, "only empty-transcription failures ride the silence rule")
    }

    // MARK: - Session staleness (C2)

    func testStaleSessionAfterEngineSkipsPolishAndCleansUpAudio() async {
        let host = HostSpy()
        host.currentSessionID = 99
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest(sessionID: 7)) {
            self.makeOutput()
        } captureResultOnFailure: {
            nil
        }

        XCTAssertEqual(host.staleCleanups.count, 1)
        XCTAssertEqual(host.staleCleanups.first?.audioURL, audioURL)
        XCTAssertEqual(host.staleCleanups.first?.sessionID, 7)

        XCTAssertTrue(host.polishedTranscripts.isEmpty)
        XCTAssertTrue(host.deliveredTexts.isEmpty)
        XCTAssertTrue(host.completedPersists.isEmpty)
        XCTAssertEqual(host.clearedSessionCount, 0)
    }

    func testStaleSessionAfterPolishSkipsDeliveryAndCleansUpAudio() async {
        let host = HostSpy()
        host.becomesStaleDuringPolish = true
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest()) {
            self.makeOutput()
        } captureResultOnFailure: {
            nil
        }

        XCTAssertEqual(host.polishedTranscripts.count, 1)
        XCTAssertEqual(host.staleCleanups.count, 1)
        XCTAssertTrue(host.deliveredTexts.isEmpty)
        XCTAssertTrue(host.completedPersists.isEmpty)
    }

    func testStaleFailureCleansUpCaptureAudioWithoutPresenting() async {
        let host = HostSpy()
        host.currentSessionID = 99
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest(sessionID: 7)) {
            throw TranscriptionFailure(kind: .network, engine: "Deepgram")
        } captureResultOnFailure: {
            (self.audioURL, 3.0)
        }

        XCTAssertEqual(host.staleCleanups.count, 1)
        XCTAssertTrue(host.presentedFailures.isEmpty)
        XCTAssertTrue(host.failedPersists.isEmpty)
    }

    func testStaleFailureWithoutCaptureResultIsSilent() async {
        let host = HostSpy()
        host.currentSessionID = 99
        let pipeline = TranscriptionPipeline(host: host)

        await pipeline.run(makeRequest(sessionID: 7)) {
            throw TranscriptionFailure(kind: .network, engine: "Deepgram")
        } captureResultOnFailure: {
            nil
        }

        XCTAssertTrue(host.staleCleanups.isEmpty)
        XCTAssertTrue(host.presentedFailures.isEmpty)
        XCTAssertTrue(host.failedPersists.isEmpty)
    }
}
