//
//  SessionAudioLevelTrackerTests.swift
//  SapoWhisperTests
//
//  No-speech fast-path thresholds: the 0.085 peak boundary (`<` = silent),
//  the 0.02 mic-connected collapse, and the 3 s hint delay gated by the
//  connecting label.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class SessionAudioLevelTrackerTests: XCTestCase {

    func testPeakBelowThresholdLooksSilent() {
        var tracker = SessionAudioLevelTracker()
        tracker.beginSession(at: 0)
        tracker.register(level: 0.084, now: 1)
        XCTAssertTrue(tracker.looksSilent)
        XCTAssertEqual(tracker.peak, 0.084)
    }

    func testPeakAtThresholdIsNotSilent() {
        var tracker = SessionAudioLevelTracker()
        tracker.beginSession(at: 0)
        tracker.register(level: 0.085, now: 1)
        XCTAssertFalse(tracker.looksSilent, "the silence comparison is strict `<`")
    }

    func testPeakTracksSessionMaximum() {
        var tracker = SessionAudioLevelTracker()
        tracker.beginSession(at: 0)
        tracker.register(level: 0.3, now: 1)
        tracker.register(level: 0.05, now: 2)
        XCTAssertEqual(tracker.peak, 0.3)
        XCTAssertFalse(tracker.looksSilent)

        tracker.beginSession(at: 10)
        XCTAssertEqual(tracker.peak, 0)
        XCTAssertTrue(tracker.looksSilent, "a new session forgets the previous peak")
    }

    func testMicConnectedCollapseThreshold() {
        let tracker = SessionAudioLevelTracker()
        XCTAssertFalse(tracker.micConnectedCollapse(level: 0.02), "the collapse comparison is strict `>`")
        XCTAssertTrue(tracker.micConnectedCollapse(level: 0.021))
    }

    func testNoSpeechHintRequiresThreeSilentSecondsAndNoConnectingLabel() {
        var tracker = SessionAudioLevelTracker()
        tracker.beginSession(at: 100)
        tracker.register(level: 0.01, now: 101)

        XCTAssertFalse(
            tracker.noSpeechHintActive(connectingLabelVisible: false, now: 102.9),
            "before 3 s the hint stays off"
        )
        XCTAssertTrue(tracker.noSpeechHintActive(connectingLabelVisible: false, now: 103))
        XCTAssertFalse(
            tracker.noSpeechHintActive(connectingLabelVisible: true, now: 103),
            "the connecting label owns that window"
        )

        tracker.register(level: 0.2, now: 104)
        XCTAssertFalse(
            tracker.noSpeechHintActive(connectingLabelVisible: false, now: 105),
            "a loud session never hints"
        )
    }
}
