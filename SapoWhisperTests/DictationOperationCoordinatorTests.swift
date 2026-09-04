import XCTest

@testable import SapoWhisper

@MainActor
final class DictationOperationCoordinatorTests: XCTestCase {
    private func context(_ id: UInt64) -> DictationOperationCoordinator.Context {
        .init(sessionID: id, historyId: Int64(id), audioURL: nil, duration: 2, variant: .localAIServer)
    }

    func testCancelledOperationKeepsOwnershipUntilItActuallyFinishes() async {
        let coordinator = DictationOperationCoordinator()
        var release: CheckedContinuation<Void, Never>?
        var cancellationCalls = 0
        let task = Task {
            await coordinator.run(context(1)) {
                cancellationCalls += 1
            } operation: {
                await withCheckedContinuation { release = $0 }
            }
        }
        for _ in 0..<1000 where release == nil { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(release)
        coordinator.cancel(sessionID: 1)
        coordinator.cancel(sessionID: 1)
        XCTAssertEqual(cancellationCalls, 1)
        XCTAssertEqual(coordinator.active?.sessionID, 1)
        let overlap = await coordinator.run(context(2)) { XCTFail("Overlapping operation must not run") }
        XCTAssertFalse(overlap)
        release?.resume()
        _ = await task.value
        XCTAssertNil(coordinator.active)
        let next = await coordinator.run(context(2)) {}
        XCTAssertTrue(next)
    }

    func testStaleCancellationCannotCloseTheCurrentEngine() async {
        let coordinator = DictationOperationCoordinator()
        var release: CheckedContinuation<Void, Never>?
        var cancellationCalls = 0
        let task = Task {
            await coordinator.run(context(2)) {
                cancellationCalls += 1
            } operation: {
                await withCheckedContinuation { release = $0 }
            }
        }
        for _ in 0..<1000 where release == nil { try? await Task.sleep(for: .milliseconds(1)) }
        coordinator.cancel(sessionID: 1)
        XCTAssertEqual(cancellationCalls, 0)
        XCTAssertEqual(coordinator.active?.sessionID, 2)
        release?.resume()
        _ = await task.value
    }
}
