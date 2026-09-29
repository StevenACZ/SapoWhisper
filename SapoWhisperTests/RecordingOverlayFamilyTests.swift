//
//  RecordingOverlayFamilyTests.swift
//  SapoWhisperTests
//

@testable import SapoWhisper
import XCTest

@MainActor
final class RecordingOverlayFamilyTests: XCTestCase {

    func testDictationPhasesShareOnePill() {
        let phases: [RecordingOverlayState] = [
            .recording(duration: 3),
            .paused(duration: 3),
            .transcribing,
            .polishing(timeoutSeconds: 20, compact: false),
        ]
        XCTAssertEqual(Set(phases.map(\.contentFamily)).count, 1)
    }

    func testOtherPillsKeepTheirOwnIdentity() {
        XCTAssertNotEqual(RecordingOverlayState.transcribing.contentFamily, RecordingOverlayState.copied(outcome: .standard).contentFamily)
        XCTAssertEqual(RecordingOverlayState.cancelled.contentFamily, "cancelled")
        XCTAssertEqual(RecordingOverlayState.docked.contentFamily, "docked")
    }
}
