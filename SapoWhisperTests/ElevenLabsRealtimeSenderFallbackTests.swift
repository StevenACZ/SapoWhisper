//
//  ElevenLabsRealtimeSenderFallbackTests.swift
//  SapoWhisperTests
//
//  The drain deadline cancels the socket with sends still in flight.
//  Those chunks never reach the server and never reach `failedMessages`, so a
//  counter-only check ships a silently truncated transcript as a success.
//

import XCTest

@testable import SapoWhisper

final class ElevenLabsRealtimeSenderFallbackTests: XCTestCase {

    private func stats(failedMessages: Int, drainTimedOut: Bool) -> ElevenLabsRealtimeAudioSenderStats {
        ElevenLabsRealtimeAudioSenderStats(
            enqueuedChunks: 40,
            sentMessages: 40 - failedMessages,
            failedMessages: failedMessages,
            enqueuedBytes: 256_000,
            sentAudioBytes: 256_000,
            maxBufferedBytes: 6_400,
            maxSendWaitMs: 2_000,
            timedOutSends: 0,
            drainTimedOut: drainTimedOut
        )
    }

    func testDrainTimeoutFallsBackToBatchDespiteZeroFailedMessages() {
        let timedOut = stats(failedMessages: 0, drainTimedOut: true)

        XCTAssertEqual(timedOut.failedMessages, 0, "the cancelled sends are never counted as failed")
        XCTAssertTrue(
            ElevenLabsScribeRealtimeTranscriber.shouldFallBackToBatch(senderStats: timedOut),
            "an incomplete drain must batch the preserved WAV, not paste the truncated realtime text"
        )
    }

    func testFailedSendsStillFallBackToBatch() {
        XCTAssertTrue(
            ElevenLabsScribeRealtimeTranscriber.shouldFallBackToBatch(
                senderStats: stats(failedMessages: 3, drainTimedOut: false)
            )
        )
    }

    func testCleanDrainKeepsTheRealtimeTranscript() {
        XCTAssertFalse(
            ElevenLabsScribeRealtimeTranscriber.shouldFallBackToBatch(
                senderStats: stats(failedMessages: 0, drainTimedOut: false)
            )
        )
    }
}
