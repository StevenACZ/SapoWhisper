import Foundation
import XCTest
import os

@testable import SapoWhisper

@MainActor
final class DeepgramFluxStopFinalizationTests: XCTestCase {
    func testFluxUsesOneSecondStopTailWithoutChangingOtherEngines() {
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .deepgramFluxLive), 1.0)
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .deepgramNova3), 0.12)
        XCTAssertEqual(SapoWhisperViewModel.stopTailPadding(for: .elevenLabsScribeRealtime), 0.12)
    }

    func testStaleEndOfTurnCannotFinalizeBeforeCorrectedTurnArrives() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        var gate = DeepgramFluxFinalizationGate()

        accumulator.update(with: ["event": "EndOfTurn", "turn_index": 0, "transcript": "P"])
        gate.beginCloseStream()
        XCTAssertFalse(gate.canFinish)

        accumulator.update(with: ["event": "EndOfTurn", "turn_index": 0, "transcript": "Pepe"])
        XCTAssertFalse(gate.canFinish)

        gate.completeReceive(closeCode: .normalClosure)
        XCTAssertTrue(gate.canFinish)
        XCTAssertEqual(accumulator.transcript, "Pepe")
    }

    func testReceiveCompletionBeforeCloseStreamIsNotFinal() {
        var gate = DeepgramFluxFinalizationGate()
        gate.completeReceive(closeCode: .normalClosure)
        XCTAssertFalse(gate.canFinish)
        XCTAssertEqual(gate.completion, .pending)

        gate.beginCloseStream()
        XCTAssertEqual(gate.completion, .failed)
    }

    func testNormalWebSocketCompletionAfterCloseStreamSucceeds() {
        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.completeReceive(closeCode: .normalClosure)

        XCTAssertEqual(gate.completion, .succeeded)
    }

    func testAbnormalWebSocketCompletionAfterCloseStreamFails() {
        var gate = DeepgramFluxFinalizationGate()
        gate.beginCloseStream()
        gate.completeReceive(closeCode: .abnormalClosure)

        XCTAssertEqual(gate.completion, .failed)
    }

    func testFinishSendsSubChunkRemainder() async {
        let payload = Data(repeating: 7, count: 2_559)
        let sentPayloads = OSAllocatedUnfairLock(initialState: [Data]())
        let sender = DeepgramFluxAudioSender()
        sender.start { data, completion in
            sentPayloads.withLock { $0.append(data) }
            completion(nil)
        }

        XCTAssertTrue(sender.enqueue(payload))
        let stats = await sender.finishAndWait(timeout: 1.0)

        XCTAssertEqual(sentPayloads.withLock { $0 }, [payload])
        XCTAssertEqual(stats.enqueuedChunks, 1)
        XCTAssertEqual(stats.sentChunks, 1)
        XCTAssertEqual(stats.sentBytes, payload.count)
        XCTAssertEqual(stats.pendingChunks, 0)
    }

    func testAudioArrivingAfterSealIsExplicitlyRejected() async {
        let sender = DeepgramFluxAudioSender()
        sender.start { _, completion in completion(nil) }

        sender.sealAndFlushPendingAudio()
        XCTAssertFalse(sender.enqueue(Data(repeating: 1, count: 320)))
        let stats = await sender.finishAndWait(timeout: 1.0)

        XCTAssertEqual(stats.rejectedChunks, 1)
        XCTAssertEqual(stats.rejectedBytes, 320)
        XCTAssertEqual(stats.pendingChunks, 0)
    }
}
