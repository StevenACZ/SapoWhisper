//
//  DoubleTapRecognizerTests.swift
//  SapoWhisperTests
//
//  Double-modifier decision core: second-tap window 0.45 s, holds over
//  0.40 s never arm, the suppressed (triggering) press's release does not
//  re-arm, and any other modifier resets the sequence.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class DoubleTapRecognizerTests: XCTestCase {

    private var recognizer = DoubleTapRecognizer()

    /// Target modifier goes down alone.
    private func press(at time: CFAbsoluteTime) -> DoubleTapRecognizer.Event {
        recognizer.handle(targetOnlyDown: true, targetUp: false, otherFlagsActive: false, now: time)
    }

    /// Target modifier releases (no flags remain).
    private func release(at time: CFAbsoluteTime) -> DoubleTapRecognizer.Event {
        recognizer.handle(targetOnlyDown: false, targetUp: true, otherFlagsActive: true, now: time)
    }

    /// Another modifier is active alongside (or instead of) the target.
    private func chord(at time: CFAbsoluteTime) -> DoubleTapRecognizer.Event {
        recognizer.handle(targetOnlyDown: false, targetUp: false, otherFlagsActive: true, now: time)
    }

    override func setUp() async throws {
        try await super.setUp()
        recognizer = DoubleTapRecognizer()
    }

    func testSecondTapWithinWindowTriggers() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .firstTap)
        XCTAssertEqual(press(at: 0.5), .trigger, "0.4 s after the release is inside the 0.45 s window")
    }

    func testSecondTapAfterWindowIsAFreshFirstTap() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .firstTap)
        XCTAssertEqual(press(at: 0.6), .none, "past the 0.45 s window the press must not trigger")
        XCTAssertEqual(release(at: 0.7), .firstTap, "it starts a new sequence instead")
    }

    func testHoldLongerThanMaxDurationNeverArms() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.5), .none, "holds over 0.40 s are not taps")
        XCTAssertEqual(press(at: 0.6), .none, "no window was armed, so no trigger")
    }

    func testSuppressedPressReleaseDoesNotRearm() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .firstTap)
        XCTAssertEqual(press(at: 0.2), .trigger)
        XCTAssertEqual(release(at: 0.3), .none, "the triggering press's release must stay silent")
        XCTAssertEqual(press(at: 0.4), .none, "and must not have re-armed the window")
    }

    func testThirdModifierMidSequenceResets() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .firstTap)
        XCTAssertEqual(chord(at: 0.2), .none)
        XCTAssertEqual(press(at: 0.3), .none, "the chord reset the armed window")
    }

    func testChordedFlagsNeverArm() {
        XCTAssertEqual(chord(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .none, "releasing a chorded press is not a tap")
        XCTAssertEqual(press(at: 0.2), .none, "nothing was armed by the chord")
    }

    func testTriggerRequiresTargetOnlyDown() {
        XCTAssertEqual(press(at: 0), .none)
        XCTAssertEqual(release(at: 0.1), .firstTap)
        // Target comes back down WITH another modifier: no trigger, reset.
        XCTAssertEqual(chord(at: 0.2), .none)
        XCTAssertEqual(release(at: 0.3), .none)
    }
}
