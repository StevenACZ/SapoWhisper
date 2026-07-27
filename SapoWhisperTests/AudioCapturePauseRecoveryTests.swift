//
//  AudioCapturePauseRecoveryTests.swift
//  SapoWhisperTests
//
//  A configuration change while the dictation is paused must never
//  drive capture recovery — recovery rebuilds and restarts the engine, which
//  would keep recording audio the user asked to stop.
//

import Foundation
import XCTest

@testable import SapoWhisper

final class AudioCapturePauseRecoveryTests: XCTestCase {

    private func makeEngine(paused: Bool) -> AudioCaptureEngine {
        let engine = AudioCaptureEngine(mode: .batch)
        engine.isPaused = paused
        return engine
    }

    func testPausedCaptureNeverRecovers() {
        let engine = makeEngine(paused: true)

        XCTAssertFalse(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: false, lastBufferAge: nil))
        XCTAssertFalse(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: false, lastBufferAge: 30))
        XCTAssertFalse(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: true, lastBufferAge: 30))
    }

    func testTheSameStalledStateRecoversWhenNotPaused() {
        let engine = makeEngine(paused: false)

        XCTAssertTrue(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: false, lastBufferAge: nil))
        XCTAssertTrue(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: false, lastBufferAge: 30))
        XCTAssertTrue(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: true, lastBufferAge: 30))
    }

    func testRunningCaptureWithFreshBuffersIsLeftAlone() {
        let engine = makeEngine(paused: false)

        XCTAssertFalse(engine.shouldRecoverAfterConfigurationChange(isEngineRunning: true, lastBufferAge: 0.1))
    }
}
