import Foundation
import XCTest

@testable import SapoWhisper

final class AudioPreparationEpochTests: XCTestCase {
    func testPreparationWorkerIsSharedWithinEpochAndReplacedAfterAdvance() throws {
        let quarantine = AudioInputSetupQuarantine()
        let first = try XCTUnwrap(quarantine.preparationContext()).worker
        XCTAssertTrue(first === (try XCTUnwrap(quarantine.preparationContext())).worker)
        quarantine.advanceRouteEpoch()
        let next = try XCTUnwrap(quarantine.preparationContext()).worker
        XCTAssertFalse(first === next)
        XCTAssertTrue(next === (try XCTUnwrap(quarantine.preparationContext())).worker)
    }

    func testNewEpochRunsWhileOldSerialWorkerRemainsBlocked() throws {
        let quarantine = AudioInputSetupQuarantine()
        let oldWorker = try XCTUnwrap(quarantine.preparationContext()).worker
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let oldFollower = DispatchSemaphore(value: 0)
        let newCompleted = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            oldWorker.sync {}
        }
        oldWorker.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try XCTUnwrap(quarantine.preparationContext()).worker.async { oldFollower.signal() }
        XCTAssertEqual(oldFollower.wait(timeout: .now() + 0.05), .timedOut)

        quarantine.advanceRouteEpoch()
        try XCTUnwrap(quarantine.preparationContext()).worker.async { newCompleted.signal() }
        XCTAssertEqual(newCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(oldFollower.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testPreparationContextRejectsQuarantineAndIgnoresAnOldTimeout() throws {
        let quarantine = AudioInputSetupQuarantine()
        let original = try XCTUnwrap(quarantine.preparationContext())
        quarantine.quarantine(epoch: original.epoch)
        XCTAssertNil(quarantine.preparationContext())

        quarantine.advanceRouteEpoch()
        let current = try XCTUnwrap(quarantine.preparationContext())
        XCTAssertNotEqual(current.epoch, original.epoch)
        XCTAssertFalse(original.worker === current.worker)
        quarantine.quarantine(epoch: original.epoch)
        XCTAssertNotNil(quarantine.preparationContext())
        XCTAssertTrue(quarantine.canAttempt(epoch: current.epoch))
    }
}
