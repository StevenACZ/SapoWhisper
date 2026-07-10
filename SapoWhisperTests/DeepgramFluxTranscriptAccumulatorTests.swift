//
//  DeepgramFluxTranscriptAccumulatorTests.swift
//  SapoWhisperTests
//
//  Flux transcript assembly: turn-indexed messages own the transcript (in
//  turn order, regardless of arrival), fragments only matter when no turns
//  arrived, and noise (whitespace, missing keys) is ignored.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class DeepgramFluxTranscriptAccumulatorTests: XCTestCase {

    func testTurnIndexOrderingWinsOverArrivalOrder() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        accumulator.update(with: ["transcript": "segundo turno", "turn_index": 1])
        accumulator.update(with: ["transcript": "primer turno", "turn_index": 0])
        XCTAssertEqual(accumulator.transcript, "primer turno segundo turno")
    }

    func testLaterMessageForSameTurnReplacesIt() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        accumulator.update(with: ["transcript": "hola mun", "turn_index": 0])
        accumulator.update(with: ["transcript": "hola mundo", "turn_index": 0])
        XCTAssertEqual(accumulator.transcript, "hola mundo")
    }

    func testTurnsPresentIgnoreFragments() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        accumulator.update(with: ["transcript": "fragmento suelto"])
        accumulator.update(with: ["transcript": "turno real", "turn_index": 0])
        XCTAssertEqual(accumulator.transcript, "turno real")
    }

    func testConsecutiveDuplicateFragmentsDeduplicate() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        accumulator.update(with: ["transcript": "hola"])
        accumulator.update(with: ["transcript": "hola"])
        accumulator.update(with: ["transcript": "mundo"])
        accumulator.update(with: ["transcript": "hola"])
        XCTAssertEqual(accumulator.transcript, "hola mundo hola", "only CONSECUTIVE duplicates collapse")
    }

    func testWhitespaceOnlyTranscriptsAreSkipped() {
        var accumulator = DeepgramFluxTranscriptAccumulator()
        accumulator.update(with: ["transcript": "   \n"])
        accumulator.update(with: ["transcript": "  hola  "])
        XCTAssertEqual(accumulator.transcript, "hola")
    }

    func testEmptyAccumulatorProducesEmptyTranscript() {
        let accumulator = DeepgramFluxTranscriptAccumulator()
        XCTAssertEqual(accumulator.transcript, "")

        var withNoise = DeepgramFluxTranscriptAccumulator()
        withNoise.update(with: ["type": "TurnInfo"])
        withNoise.update(with: ["transcript": "  "])
        XCTAssertEqual(withNoise.transcript, "")
    }
}
