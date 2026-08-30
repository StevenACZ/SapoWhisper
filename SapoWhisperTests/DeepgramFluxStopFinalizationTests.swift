import Foundation
import XCTest
import os

@testable import SapoWhisper

@MainActor
final class DeepgramFluxStopFinalizationTests: XCTestCase {
    func testFluxUsesQualifiedStopTailWithoutChangingOtherEngines() {
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .deepgramFluxLive), 0.4)
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .deepgramNova3), 0.12)
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .elevenLabsScribeRealtime), 0.12)
        XCTAssertEqual(DeepgramFluxLiveTranscriber.preCloseAudioCoverageTolerance, 0.22)
    }

    func testEmptyRealtimeTranscriptFallsBackToBatch() {
        XCTAssertTrue(DeepgramFluxLiveTranscriber.shouldFallBackForEmptyRealtimeTranscript(""))
        XCTAssertTrue(DeepgramFluxLiveTranscriber.shouldFallBackForEmptyRealtimeTranscript(" \n "))
        XCTAssertFalse(DeepgramFluxLiveTranscriber.shouldFallBackForEmptyRealtimeTranscript("texto final"))
    }

    func testStaleEndOfTurnCannotFinalizeBeforeCorrectedTurnArrives() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: ["event": "EndOfTurn", "turn_index": 0, "transcript": "P"])
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        XCTAssertFalse(gate.canFinish)

        accumulator.update(with: ["event": "Update", "turn_index": 0, "transcript": "Pepe"])
        gate.recordTurnInfo(isUpdate: true)
        XCTAssertFalse(gate.canFinish)

        gate.completeReceive(closeCode: .normalClosure, latestTurnInfoIsUpdate: true)
        XCTAssertTrue(gate.canFinish)
        XCTAssertEqual(accumulator.transcript, "Pepe")
    }

    func testReceiveCompletionBeforeCloseStreamIsNotFinal() {
        var gate = DeepgramFluxFinalizationGate()
        gate.completeReceive(closeCode: .normalClosure, latestTurnInfoIsUpdate: true)
        XCTAssertFalse(gate.canFinish)
        XCTAssertEqual(gate.completion, .pending)

        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        XCTAssertEqual(gate.completion, .failed)
    }

    func testNormalWebSocketCompletionAfterCloseStreamSucceeds() {
        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.recordTurnInfo(isUpdate: true)
        gate.completeReceive(closeCode: .normalClosure, latestTurnInfoIsUpdate: true)

        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testPostCloseNonUpdateTurnInfoDoesNotFinalize() {
        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.recordTurnInfo(isUpdate: false)
        gate.completeReceive(closeCode: .normalClosure)

        XCTAssertEqual(gate.completion, .failed)
    }

    func testAbnormalWebSocketCompletionAfterCloseStreamFails() {
        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.recordTurnInfo(isUpdate: true)
        gate.completeReceive(closeCode: .abnormalClosure, latestTurnInfoIsUpdate: true)

        XCTAssertEqual(gate.completion, .failed)
    }

    func testObservedPeerCloseAfterCloseStreamUsesFinalTranscript() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        XCTAssertTrue(
            DeepgramFluxLiveTranscriber.isExpectedPeerCloseAfterCloseStream(
                closeCode: closeCode.rawValue,
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(ENOTCONN),
                hasTranscript: true
            )
        )

        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.recordTurnInfo(isUpdate: true)
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: true
        )
        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testPeerCloseCannotFinalizeWithoutAnUpdate() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: ["type": "TurnInfo", "turn_index": 0, "transcript": "texto previo"])
        gate.recordTurnInfo(isUpdate: false)
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
        )

        XCTAssertFalse(accumulator.transcript.isEmpty)
        XCTAssertFalse(gate.receivedTurnInfoAfterCloseStream)
        XCTAssertEqual(gate.completion, .failed)
    }

    func testPeerCloseCannotUseAnUpdateReceivedBeforeCloseStream() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0, "audio_window_end": 8.9,
            "transcript": "texto completo",
        ])
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
                && !accumulator.transcript.isEmpty
        )

        XCTAssertEqual(accumulator.latestAudioWindowEnd, 8.9)
        XCTAssertFalse(gate.receivedUpdateAfterCloseStream)
        XCTAssertEqual(gate.completion, .failed)
    }

    func testPeerCloseUsesAnUpdateReceivedAfterCloseStream() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "transcript": "texto completo",
        ])
        gate.recordTurnInfo(
            isUpdate: accumulator.latestEvent == "Update" && accumulator.latestUpdateApplied
        )
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
                && accumulator.latestUpdateApplied
                && !accumulator.transcript.isEmpty
        )

        XCTAssertTrue(gate.receivedUpdateAfterCloseStream)
        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testPeerCloseUsesCoveredPreCloseUpdateAfterConfirmedSend() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "audio_window_end": 8.9, "transcript": "texto completo",
        ])
        gate.beginCloseStream(
            preCloseUpdateConfirmed: accumulator.latestEvent == "Update"
                && accumulator.latestUpdateApplied
                && accumulator.coversAudio(through: 8.8)
        )
        gate.confirmCloseStreamSent()
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
                && accumulator.latestUpdateApplied
                && !accumulator.transcript.isEmpty
        )

        XCTAssertTrue(gate.preCloseUpdateConfirmed)
        XCTAssertFalse(gate.receivedUpdateAfterCloseStream)
        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testPeerCloseRejectsPreCloseUpdateOutsideCoverageWindow() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "audio_window_end": 8.5, "transcript": "texto parcial",
        ])
        gate.beginCloseStream(
            preCloseUpdateConfirmed: accumulator.latestEvent == "Update"
                && accumulator.latestUpdateApplied
                && accumulator.coversAudio(through: 8.8)
        )
        gate.confirmCloseStreamSent()
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: true
        )

        XCTAssertFalse(gate.preCloseUpdateConfirmed)
        XCTAssertEqual(gate.completion, .failed)
    }

    func testLatestNonUpdateTurnInfoFailsClosed() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "EndOfTurn", "turn_index": 0,
            "audio_window_end": 8.9, "transcript": "texto anterior",
        ])
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
                && !accumulator.transcript.isEmpty
        )

        XCTAssertEqual(gate.completion, .failed)
    }

    func testFinalEmptyUpdateReplacesStaleTextAndFailsClosed() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "transcript": "texto parcial",
        ])
        gate.beginCloseStream()
        gate.confirmCloseStreamSent()
        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "transcript": "   ",
        ])
        gate.recordTurnInfo(
            isUpdate: accumulator.latestEvent == "Update" && accumulator.latestUpdateApplied
        )
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: accumulator.latestEvent == "Update"
                && accumulator.latestUpdateApplied
                && !accumulator.transcript.isEmpty
        )

        XCTAssertTrue(accumulator.latestUpdateApplied)
        XCTAssertTrue(accumulator.transcript.isEmpty)
        XCTAssertEqual(gate.completion, .failed)
    }

    func testUpdateAndClosureDuringSendAwaitCompleteAfterConfirmation() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var gate = DeepgramFluxFinalizationGate()

        gate.beginCloseStream()
        gate.recordTurnInfo(isUpdate: true)
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: true
        )

        XCTAssertFalse(gate.closeStreamSendConfirmed)
        XCTAssertEqual(gate.completion, .pending)

        gate.confirmCloseStreamSent()

        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testInvalidClosureDuringSendAwaitFailsAfterConfirmation() {
        let closeCode = try! XCTUnwrap(URLSessionWebSocketTask.CloseCode(rawValue: 1_005))
        var gate = DeepgramFluxFinalizationGate()

        gate.beginCloseStream()
        gate.recordTurnInfo(isUpdate: false)
        gate.completeReceive(
            closeCode: closeCode,
            acceptedPeerClose: true,
            latestTurnInfoIsUpdate: false
        )

        XCTAssertEqual(gate.completion, .pending)

        gate.confirmCloseStreamSent()

        XCTAssertEqual(gate.completion, .failed)
    }

    func testTurnInfoWithoutEventCannotReuseAnOlderUpdateMarker() {
        var accumulator = DeepgramFluxTranscriptAccumulator()

        accumulator.update(with: [
            "type": "TurnInfo", "event": "Update", "turn_index": 0,
            "transcript": "texto inicial",
        ])
        accumulator.update(with: [
            "type": "TurnInfo", "turn_index": 0, "transcript": "texto sin evento",
        ])

        XCTAssertNil(accumulator.latestEvent)
        XCTAssertFalse(accumulator.latestUpdateApplied)
        XCTAssertEqual(accumulator.transcript, "texto sin evento")
    }

    func testObservedPeerCloseRequiresExactErrorAndTranscript() {
        XCTAssertFalse(
            DeepgramFluxLiveTranscriber.isExpectedPeerCloseAfterCloseStream(
                closeCode: 1_005,
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(ENOTCONN),
                hasTranscript: false
            )
        )
        XCTAssertFalse(
            DeepgramFluxLiveTranscriber.isExpectedPeerCloseAfterCloseStream(
                closeCode: 1_005,
                errorDomain: NSURLErrorDomain,
                errorCode: NSURLErrorNetworkConnectionLost,
                hasTranscript: true
            )
        )
    }

    func testFinishSendsSubChunkRemainder() async {
        let payload = Data(repeating: 7, count: 2_559)
        let sentPayloads = OSAllocatedUnfairLock(initialState: [Data]())
        let sender = DeepgramFluxAudioSender()
        let session = sender.start { data, completion in
            sentPayloads.withLock { $0.append(data) }
            completion(nil)
        }

        XCTAssertTrue(sender.enqueue(payload, session: session))
        let stats = await sender.finishAndWait(session: session, timeout: 1.0)

        XCTAssertEqual(sentPayloads.withLock { $0 }, [payload])
        XCTAssertEqual(stats.enqueuedChunks, 1)
        XCTAssertEqual(stats.sentChunks, 1)
        XCTAssertEqual(stats.sentBytes, payload.count)
        XCTAssertEqual(stats.pendingChunks, 0)
    }

    func testAudioArrivingAfterSealIsExplicitlyRejected() async {
        let sender = DeepgramFluxAudioSender()
        let session = sender.start { _, completion in completion(nil) }

        sender.sealAndFlushPendingAudio(session: session)
        XCTAssertFalse(sender.enqueue(Data(repeating: 1, count: 320), session: session))
        let stats = await sender.finishAndWait(session: session, timeout: 1.0)

        XCTAssertEqual(stats.rejectedChunks, 1)
        XCTAssertEqual(stats.rejectedBytes, 320)
        XCTAssertEqual(stats.pendingChunks, 0)
    }
}
