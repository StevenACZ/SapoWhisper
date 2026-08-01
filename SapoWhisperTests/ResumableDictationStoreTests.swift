//
//  ResumableDictationStoreTests.swift
//  SapoWhisperTests
//
//  Continue-previous offer lifecycle: 30-minute expiry, audio-file-existence
//  invalidation (both clear the stored offer, not just hide it), and the
//  one-shot merge opt-in.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class ResumableDictationStoreTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func makeOffer() -> ResumableDictation {
        ResumableDictation(
            historyId: 7,
            audioURL: URL(fileURLWithPath: "/tmp/resumable-test.wav"),
            duration: 12,
            capturedAt: capturedAt
        )
    }

    /// Store whose clock reads `capturedAt + offset` and whose audio file
    /// always exists — the common valid baseline.
    private func makeStore(offset: TimeInterval) -> ResumableDictationStore {
        let frozenNow = capturedAt.addingTimeInterval(offset)
        return ResumableDictationStore(now: { frozenNow }, fileExists: { _ in true })
    }

    func testValidOfferWithinWindow() {
        let store = makeStore(offset: 30 * 60 - 1)
        store.offer(makeOffer())
        XCTAssertEqual(store.validOffer?.historyId, 7)
        XCTAssertEqual(store.validOffer?.duration, 12)
    }

    func testExpiredOfferIsClearedNotJustHidden() {
        var now = capturedAt.addingTimeInterval(30 * 60 + 1)
        let store = ResumableDictationStore(now: { now }, fileExists: { _ in true })
        store.offer(makeOffer())

        XCTAssertNil(store.validOffer, "offers older than 30 minutes are stale")

        // Even back inside the window, the expired offer stays gone.
        now = capturedAt
        XCTAssertNil(store.validOffer)
    }

    func testMissingAudioFileClearsOffer() {
        let frozenNow = capturedAt.addingTimeInterval(60)
        var fileOnDisk = false
        let store = ResumableDictationStore(now: { frozenNow }, fileExists: { _ in fileOnDisk })
        store.offer(makeOffer())

        XCTAssertNil(store.validOffer, "an offer whose audio is gone is invalid")

        // The file reappearing cannot resurrect a cleared offer.
        fileOnDisk = true
        XCTAssertNil(store.validOffer)
    }

    func testConsumeRequestedMergeDropsTheOptIn() {
        let store = makeStore(offset: 60)
        store.offer(makeOffer())

        store.mergeRequested = true
        XCTAssertEqual(store.consumeRequestedMerge()?.historyId, 7)
        XCTAssertFalse(store.mergeRequested, "the opt-in is one-shot")
        XCTAssertNil(store.consumeRequestedMerge(), "a second consume needs a new opt-in")
        XCTAssertNotNil(store.validOffer, "consuming the opt-in keeps the offer until the merge succeeds")

        store.clearOffer()
        XCTAssertNil(store.validOffer)
    }

    func testConsumeWithoutOptInReturnsNil() {
        let store = makeStore(offset: 60)
        store.offer(makeOffer())
        XCTAssertNil(store.consumeRequestedMerge())
        XCTAssertNotNil(store.validOffer)
    }

    func testClearOfferForMatchingHistoryIdClears() {
        let store = makeStore(offset: 60)
        store.offer(makeOffer())

        XCTAssertTrue(store.clearOffer(forHistoryId: 7))
        XCTAssertNil(store.validOffer, "a retranscribed take must stop being offered")
    }

    func testClearOfferForDifferentHistoryIdKeepsOffer() {
        let store = makeStore(offset: 60)
        store.offer(makeOffer())

        XCTAssertFalse(store.clearOffer(forHistoryId: 8))
        XCTAssertEqual(store.validOffer?.historyId, 7)
    }

    func testFormatResumeDuration() {
        XCTAssertEqual(ResumableDictationStore.formatResumeDuration(0), "0:00")
        XCTAssertEqual(ResumableDictationStore.formatResumeDuration(9.4), "0:09")
        XCTAssertEqual(ResumableDictationStore.formatResumeDuration(75), "1:15")
        XCTAssertEqual(ResumableDictationStore.formatResumeDuration(-3), "0:00")
    }
}
