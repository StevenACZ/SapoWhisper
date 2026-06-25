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

    func testUserCancelledIsNotRetryable() {
        let failure = TranscriptionFailure(kind: .userCancelled, engine: "WhisperKit")
        XCTAssertFalse(failure.isRetryable)

        let errorState = ErrorState(failure: failure)
        XCTAssertEqual(errorState.kind, .userCancelled)
        XCTAssertFalse(errorState.isRetryable)
        XCTAssertFalse(errorState.isNoSpeech)
    }

    func testBodySnippetRedactsSecrets() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 500,
            body: Data("{\"api_key\": \"sk-supersecretvalue123456\"}".utf8))
        XCTAssertFalse(failure.logSummary.contains("supersecretvalue"))
    }

    func testRedactsBearerTokenInColonSpaceHeader() {
        // Regression: the generic key pattern used to consume only the word
        // "Bearer" (it stops at the space), stranding the token. The scheme
        // pattern now runs first and must redact the whole token.
        let failure = TranscriptionFailure.fromHTTP(
            engine: "ElevenLabs", statusCode: 500,
            body: Data("Authorization: Bearer supersecret-bearer-token-1234567".utf8))
        XCTAssertFalse(failure.logSummary.contains("supersecret-bearer-token-1234567"))
    }

    func testRedactsDeepgramTokenScheme() {
        // Deepgram authenticates with "Token <key>"; "Token" is < 6 chars so the
        // generic pattern never fired — the scheme pattern must catch it.
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 500,
            body: Data("Authorization: Token deepgram_secret_key_0123456789".utf8))
        XCTAssertFalse(failure.logSummary.contains("deepgram_secret_key_0123456789"))
    }

    func testRedactsBareSkAndAIzaKeys() {
        let sk = TranscriptionFailure.fromHTTP(
            engine: "OpenAI", statusCode: 500,
            body: Data("{\"error\":\"key sk-abcdef0123456789 invalid\"}".utf8))
        XCTAssertFalse(sk.logSummary.contains("abcdef0123456789"))
        let aiza = TranscriptionFailure.fromHTTP(
            engine: "Gemini", statusCode: 500,
            body: Data("{\"error\":\"AIzaSyABCDEF0123456789xyz bad\"}".utf8))
        XCTAssertFalse(aiza.logSummary.contains("AIzaSyABCDEF0123456789xyz"))
    }

    func testRedactsProviderMaskedOpenAICompatibleKeys() {
        let snippet = TranscriptionFailure.redactedLogSnippet(
            from:
                "Incorrect API key provided: sk-or-v1******************************eb76. You can find your API key at https://platform.openai.com/api-keys."
        )

        XCTAssertFalse(snippet.contains("sk-or-v1"))
        XCTAssertFalse(snippet.contains("eb76"))
        XCTAssertTrue(snippet.contains("[redacted-key]"))
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
        // Includes codes with no explicit case (406/409/410/411/412/423/451):
        // they must fall into the 400..<500 client-error range, not .unknown.
        for status in [400, 404, 405, 406, 409, 410, 411, 412, 413, 415, 422, 423, 451] {
            let failure = TranscriptionFailure.fromHTTP(engine: "ElevenLabs", statusCode: status, body: Data())
            XCTAssertEqual(failure.kind, .clientError, "status \(status)")
            XCTAssertFalse(failure.isRetryable, "status \(status) must not be retryable")
        }
    }

    func testHTTP408And429StayRetryableDespite4xxRange() {
        // The explicit timeout/rate-limit cases must still win over the new range.
        XCTAssertTrue(TranscriptionFailure.fromHTTP(engine: "Deepgram", statusCode: 408, body: Data()).isRetryable)
        XCTAssertTrue(
            TranscriptionFailure.fromHTTP(
                engine: "Deepgram", statusCode: 429,
                body: Data("{\"err\":\"rate limit\"}".utf8)
            ).isRetryable)
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
