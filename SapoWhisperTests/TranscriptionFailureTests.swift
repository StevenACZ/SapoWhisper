//
//  TranscriptionFailureTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class TranscriptionFailureTests: XCTestCase {

    func testCombinedFailureNamesBothServicesAndPreservesThePrimaryRetryPolicy() {
        let primary = TranscriptionFailure(kind: .network, engine: "Primary")
        let backup = TranscriptionFailure(kind: .auth, engine: "Backup")
        let failure = TranscriptionFailure.backupFailed(primary: primary, backup: backup)
        XCTAssertEqual(failure.kind, .network)
        XCTAssertEqual(failure.engine, "Primary")
        XCTAssertTrue(failure.isRetryable)
        XCTAssertTrue(failure.localizedDescription.contains("Primary"))
        XCTAssertTrue(failure.localizedDescription.contains("Backup"))
        XCTAssertTrue(failure.localizedDescription.contains(backup.localizedDescription))
        XCTAssertEqual(failure.technicalDetail, "primary=Primary/network backup=Backup/auth")
    }

    func testNetworkFailureNamesTheUnavailableService() {
        XCTAssertTrue(TranscriptionFailure(kind: .network, engine: "Fixture service").localizedDescription.contains("Fixture service"))
    }

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

    func testHTTPLogSummaryOmitsProviderBody() {
        let failure = TranscriptionFailure.fromHTTP(
            engine: "Deepgram", statusCode: 500,
            body: Data(
                "private transcript Authorization: Bearer supersecret-bearer-token-1234567".utf8
            )
        )
        XCTAssertEqual(failure.logSummary, "Deepgram/server_error detail=HTTP status=500")
        XCTAssertFalse(failure.logSummary.contains("private transcript"))
        XCTAssertFalse(failure.logSummary.contains("supersecret-bearer-token-1234567"))
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

    func testRedactsQuotedJSONSecretsWithoutLeakingValues() {
        let apiSecret = ["json", "secret", "123456"].joined(separator: "-")
        let clientSecret = ["second", "secret", "654321"].joined(separator: "-")
        let bearerSecret = ["third", "secret", "abcdef"].joined(separator: "-")
        let snippet = TranscriptionFailure.redactedLogSnippet(
            from:
                #"{"api_key":"\#(apiSecret)","client_secret": "\#(clientSecret)", "authorization":"Bearer \#(bearerSecret)"}"#
        )

        XCTAssertFalse(snippet.contains(apiSecret))
        XCTAssertFalse(snippet.contains(clientSecret))
        XCTAssertFalse(snippet.contains(bearerSecret))
        XCTAssertTrue(snippet.contains(#""api_key":"[redacted]""#))
        XCTAssertTrue(snippet.contains(#""client_secret": "[redacted]""#))
        XCTAssertTrue(snippet.contains(#""authorization":"[redacted]""#))
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

    func testFromMLXModelNotLoadedMapsToNotConfigured() {
        let failure = TranscriptionFailure.from(MLXWhisperError.modelNotLoaded, engine: "Whisper (Local)")
        XCTAssertEqual(failure.kind, .notConfigured)
        XCTAssertFalse(failure.isRetryable)
    }

    func testFromMLXTranscriptionFailedMapsToUnknown() {
        let failure = TranscriptionFailure.from(MLXWhisperError.transcriptionFailed("boom"), engine: "Whisper (Local)")
        XCTAssertEqual(failure.kind, .unknown)
    }

    func testFromAlreadyClassifiedFailurePassesThrough() {
        let original = TranscriptionFailure(kind: .auth, engine: "ElevenLabs")
        let failure = TranscriptionFailure.from(original, engine: "Deepgram")
        XCTAssertEqual(failure.kind, .auth)
        // The already-classified failure wins, keeping its original engine.
        XCTAssertEqual(failure.engine, "ElevenLabs")
    }

    func testGenericErrorDiagnosticOmitsDescriptionAndPath() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "Cannot read /private/audio.wav"]
        )
        let failure = TranscriptionFailure.from(error, engine: "Deepgram")

        XCTAssertEqual(failure.technicalDetail, "NSCocoaErrorDomain/257")
        XCTAssertFalse(failure.logSummary.contains("/private/audio.wav"))
    }
}
