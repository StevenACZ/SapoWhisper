//
//  AppStateTransitionTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

/// Pins the dictation state machine's legality table: every edge the real
/// flows take must be legal, and the clobber patterns the ViewModel's guards
/// were written against must not be.
final class AppStateTransitionTests: XCTestCase {

    private let error = AppState.error(ErrorState(message: "boom"))

    func testRealFlowEdgesAreLegal() {
        // Live dictation: start → stop → polish → deliver.
        XCTAssertTrue(AppState.idle.canTransition(to: .recording))
        XCTAssertTrue(AppState.recording.canTransition(to: .processing))
        XCTAssertTrue(AppState.processing.canTransition(to: .polishing))
        XCTAssertTrue(AppState.polishing.canTransition(to: .idle))

        // Failure surfaces from any stage; retry restarts from error or idle.
        XCTAssertTrue(AppState.recording.canTransition(to: error))
        XCTAssertTrue(AppState.processing.canTransition(to: error))
        XCTAssertTrue(AppState.polishing.canTransition(to: error))
        XCTAssertTrue(error.canTransition(to: .processing))
        XCTAssertTrue(AppState.idle.canTransition(to: .processing))

        // Repolish runs from the completed pill; no-speech resets processing.
        XCTAssertTrue(AppState.idle.canTransition(to: .polishing))
        XCTAssertTrue(AppState.processing.canTransition(to: .idle))

        // Cloud engines record without a local model; model install recovers.
        XCTAssertTrue(AppState.noModel.canTransition(to: .recording))
        XCTAssertTrue(AppState.noModel.canTransition(to: .idle))
        XCTAssertTrue(AppState.idle.canTransition(to: .noModel))
    }

    func testPublishersMayReEmitCurrentState() {
        XCTAssertTrue(AppState.recording.canTransition(to: .recording))
        XCTAssertTrue(AppState.processing.canTransition(to: .processing))
        XCTAssertTrue(error.canTransition(to: AppState.error(ErrorState(message: "other"))))
    }

    func testClobberEdgesAreIllegal() {
        // The "never clobber an active session" comments, as a table.
        XCTAssertFalse(AppState.processing.canTransition(to: .recording))
        XCTAssertFalse(AppState.polishing.canTransition(to: .recording))
        XCTAssertFalse(AppState.polishing.canTransition(to: .processing))
        XCTAssertFalse(AppState.recording.canTransition(to: .noModel))
        XCTAssertFalse(AppState.polishing.canTransition(to: .noModel))
        XCTAssertFalse(AppState.recording.canTransition(to: .polishing))
        XCTAssertFalse(AppState.noModel.canTransition(to: .polishing))
    }
}
