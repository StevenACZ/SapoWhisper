//
//  TranscriptionFailureTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class TranscriptionFailureTests: XCTestCase {

    func testHTTP401MapsToAuth() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "ElevenLabs", statusCode: 401, body: Data("{\"detail\":\"invalid api key\"}".utf8))
        XCTAssertEqual(failure.kind, .auth)
        XCTAssertFalse(failure.isRetryable)
    }

    func testHTTP402MapsToOutOfCredits() {
        let failure = TranscriptionFailure.fromHTTP(engine: "Deepgram", statusCode: 402, body: Data())
        XCTAssertEqual(failure.kind, .outOfCredits)
        XCTAssertFalse(failure.isRetryable)
    }

    func testHTTP429WithQuotaKeywordMapsToOutOfCredits() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 429, body: Data("{\"err\":\"quota exhausted, no credits left\"}".utf8))
        XCTAssertEqual(failure.kind, .outOfCredits)
    }

    func testHTTP429WithRateKeywordStaysRateLimited() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 429, body: Data("{\"err\":\"too many requests, rate limit\"}".utf8))
        XCTAssertEqual(failure.kind, .rateLimited)
        XCTAssertTrue(failure.isRetryable)
    }

    func testHTTP503MapsToRetryableServerError() {
        let failure = TranscriptionFailure.fromHTTP(engine: "ElevenLabs", statusCode: 503, body: Data())
        XCTAssertEqual(failure.kind, .serverError)
        XCTAssertTrue(failure.isRetryable)
    }

    func testEmptyTranscriptionIsNotRetryable() {
        let failure = TranscriptionFailure(kind: .emptyTranscription, engine: "Deepgram")
        XCTAssertFalse(failure.isRetryable)
    }

    func testBodySnippetRedactsSecrets() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 500,
            body: Data("{\"api_key\": \"sk-supersecretvalue123456\"}".utf8))
        XCTAssertFalse(failure.logSummary.contains("supersecretvalue"))
    }

    func testErrorStateTreatsNoSpeechGently() {
        let noSpeech = ErrorState(failure: TranscriptionFailure(kind: .emptyTranscription, engine: "Deepgram"))
        XCTAssertTrue(noSpeech.isNoSpeech)

        let network = ErrorState(failure: TranscriptionFailure(kind: .network, engine: "Deepgram"))
        XCTAssertFalse(network.isNoSpeech)
        XCTAssertTrue(network.isRetryable)
    }

    // MARK: - 4xx client errors (not retryable)

    func testHTTP4xxMapsToNonRetryableClientError() {
        for status in [400, 404, 405, 413, 415, 422] {
            let failure = TranscriptionFailure.fromHTTP(engine: "ElevenLabs", statusCode: status, body: Data())
            XCTAssertEqual(failure.kind, .clientError, "status \(status)")
            XCTAssertFalse(failure.isRetryable, "status \(status) must not be retryable")
        }
    }

    // MARK: - from(_:) error mapping

    func testFromURLErrorTimedOut() {
        let failure = TranscriptionFailure.from(URLError(.timedOut), engine: "Deepgram")
        XCTAssertEqual(failure.kind, .timedOut)
        XCTAssertTrue(failure.isRetryable)
    }

    func testFromURLErrorOfflineMapsToNetwork() {
        let failure = TranscriptionFailure.from(URLError(.notConnectedToInternet), engine: "Deepgram")
        XCTAssertEqual(failure.kind, .network)
        XCTAssertTrue(failure.isRetryable)
    }

    func testFromRecordingDeviceSwitchMapsToInterrupted() {
        let failure = TranscriptionFailure.from(RecordingError.noInputAfterDeviceSwitch, engine: "WhisperKit")
        XCTAssertEqual(failure.kind, .recordingInterrupted)
    }

    func testFromRecordingFileFailureMapsToCorrupt() {
        let failure = TranscriptionFailure.from(RecordingError.fileCreationFailed, engine: "WhisperKit")
        XCTAssertEqual(failure.kind, .audioCorrupt)
    }

    func testFromRecordingPermissionDeniedIsNotRetryable() {
        let failure = TranscriptionFailure.from(RecordingError.permissionDenied, engine: "WhisperKit")
        XCTAssertEqual(failure.kind, .notConfigured)
        XCTAssertFalse(failure.isRetryable)
    }

    func testFromWhisperKitModelNotLoadedMapsToNotConfigured() {
        let failure = TranscriptionFailure.from(WhisperKitError.modelNotLoaded, engine: "WhisperKit")
        XCTAssertEqual(failure.kind, .notConfigured)
        XCTAssertFalse(failure.isRetryable)
    }

    func testFromWhisperKitTranscriptionFailedMapsToUnknown() {
        let failure = TranscriptionFailure.from(WhisperKitError.transcriptionFailed("boom"), engine: "WhisperKit")
        XCTAssertEqual(failure.kind, .unknown)
    }

    func testFromAlreadyClassifiedFailurePassesThrough() {
        let original = TranscriptionFailure(kind: .auth, engine: "ElevenLabs")
        let failure = TranscriptionFailure.from(original, engine: "Deepgram")
        XCTAssertEqual(failure.kind, .auth)
        // The already-classified failure wins, keeping its original engine.
        XCTAssertEqual(failure.engine, "ElevenLabs")
    }
}
