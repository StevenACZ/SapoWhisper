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
}
