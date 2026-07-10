//
//  ElevenLabsRealtimeTranscriptAccumulatorTests.swift
//  SapoWhisperTests
//
//  Realtime transcript assembly: committed segments dedup consecutively and
//  clear the partial, the partial only counts when non-empty, and nil /
//  whitespace inputs are sanitized away.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class ElevenLabsRealtimeTranscriptAccumulatorTests: XCTestCase {

    func testRecordCommittedDedupsConsecutiveSegmentsAndClearsPartial() {
        var accumulator = ElevenLabsRealtimeTranscriptAccumulator()
        accumulator.recordPartial("hola mun")
        accumulator.recordCommitted("hola mundo")
        accumulator.recordCommitted("hola mundo")
        accumulator.recordCommitted("segunda frase")
        accumulator.recordCommitted("hola mundo")

        XCTAssertEqual(accumulator.committedCount, 3, "only CONSECUTIVE duplicates collapse")
        XCTAssertFalse(accumulator.hasUncommittedPartial, "a commit clears the pending partial")
        XCTAssertEqual(accumulator.transcript, "hola mundo segunda frase hola mundo")
    }

    func testHasUncommittedPartialOnlyForNonEmptyText() {
        var accumulator = ElevenLabsRealtimeTranscriptAccumulator()
        XCTAssertFalse(accumulator.hasUncommittedPartial)

        accumulator.recordPartial("   \n")
        XCTAssertFalse(accumulator.hasUncommittedPartial, "whitespace sanitizes to empty")

        accumulator.recordPartial(nil)
        XCTAssertFalse(accumulator.hasUncommittedPartial)

        accumulator.recordPartial("  hola ")
        XCTAssertTrue(accumulator.hasUncommittedPartial)
        XCTAssertEqual(accumulator.latestPartial, "hola")
    }

    func testTranscriptJoinsWithSingleSpacesAndTrims() {
        var accumulator = ElevenLabsRealtimeTranscriptAccumulator()
        accumulator.recordCommitted("  hola  ")
        accumulator.recordCommitted("\nmundo\n")
        XCTAssertEqual(accumulator.transcript, "hola mundo")
    }

    func testNilAndWhitespaceCommitsAreIgnored() {
        var accumulator = ElevenLabsRealtimeTranscriptAccumulator()
        accumulator.recordPartial("algo pendiente")
        accumulator.recordCommitted(nil)
        accumulator.recordCommitted("   ")

        XCTAssertEqual(accumulator.committedCount, 0)
        XCTAssertEqual(accumulator.transcript, "")
        XCTAssertTrue(accumulator.hasUncommittedPartial, "an empty commit must not clear the partial")
    }
}
