//
//  EscapeCancelGateTests.swift
//  SapoWhisperTests
//
//  Double-press Esc cancel: first press arms, second within the window
//  confirms, expiry or reset drop the armed press.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class EscapeCancelGateTests: XCTestCase {

    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    private func makeGate(_ clock: Clock) -> EscapeCancelGate {
        EscapeCancelGate(now: { clock.now })
    }

    func testFirstPressArmsAndSecondConfirmsWithinWindow() {
        let clock = Clock()
        var gate = makeGate(clock)

        XCTAssertEqual(gate.registerPress(), .armed)
        clock.advance(EscapeCancelGate.confirmWindow - 0.1)
        XCTAssertEqual(gate.registerPress(), .confirmed)
    }

    func testPressAfterWindowOnlyArmsAgain() {
        let clock = Clock()
        var gate = makeGate(clock)

        XCTAssertEqual(gate.registerPress(), .armed)
        clock.advance(EscapeCancelGate.confirmWindow + 0.1)
        XCTAssertEqual(gate.registerPress(), .armed, "an expired arm must not confirm")
        clock.advance(0.2)
        XCTAssertEqual(gate.registerPress(), .confirmed)
    }

    func testConfirmConsumesTheArmedPress() {
        let clock = Clock()
        var gate = makeGate(clock)

        XCTAssertEqual(gate.registerPress(), .armed)
        clock.advance(0.5)
        XCTAssertEqual(gate.registerPress(), .confirmed)
        clock.advance(0.5)
        XCTAssertEqual(gate.registerPress(), .armed, "a confirm starts the next cycle from scratch")
    }

    func testResetDropsTheArmedPress() {
        let clock = Clock()
        var gate = makeGate(clock)

        XCTAssertEqual(gate.registerPress(), .armed)
        gate.reset()
        clock.advance(0.2)
        XCTAssertEqual(gate.registerPress(), .armed, "a reset press cannot confirm across a boundary")
    }
}
