import Foundation
import XCTest
import os

@testable import SapoWhisper

@MainActor
final class DeepgramFluxAudioSenderSessionTests: XCTestCase {
    func testCancelledSessionCannotSendIntoReplacementSession() async {
        let firstPayload = Data(repeating: 1, count: 2_560)
        let queuedOldPayload = Data(repeating: 2, count: 2_560)
        let replacementPayload = Data(repeating: 3, count: 2_560)
        let firstSendStarted = DispatchSemaphore(value: 0)
        let releaseFirstSend = DispatchSemaphore(value: 0)
        let firstDeliveries = OSAllocatedUnfairLock(initialState: [Data]())
        let secondDeliveries = OSAllocatedUnfairLock(initialState: [Data]())
        let sender = DeepgramFluxAudioSender(firstSendTimeout: 1.0, sendTimeout: 1.0)

        let firstSession = sender.start { data, completion in
            firstDeliveries.withLock { $0.append(data) }
            firstSendStarted.signal()
            _ = releaseFirstSend.wait(timeout: .now() + 1.0)
            completion(nil)
        }
        XCTAssertTrue(sender.enqueue(firstPayload, session: firstSession))
        XCTAssertEqual(firstSendStarted.wait(timeout: .now() + 1.0), .success)
        XCTAssertTrue(sender.enqueue(queuedOldPayload, session: firstSession))

        sender.cancel(session: firstSession)
        let replacementSession = sender.start { data, completion in
            secondDeliveries.withLock { $0.append(data) }
            completion(nil)
        }
        XCTAssertTrue(sender.enqueue(replacementPayload, session: replacementSession))
        releaseFirstSend.signal()

        let oldStats = await sender.finishAndWait(session: firstSession, timeout: 1.0)
        let stats = await sender.finishAndWait(session: replacementSession, timeout: 1.0)

        XCTAssertEqual(firstDeliveries.withLock { $0 }, [firstPayload])
        XCTAssertEqual(oldStats.enqueuedChunks, 2)
        XCTAssertEqual(oldStats.failedChunks, 2)
        XCTAssertEqual(secondDeliveries.withLock { $0 }, [replacementPayload])
        XCTAssertEqual(stats.enqueuedChunks, 1)
        XCTAssertEqual(stats.sentChunks, 1)
        XCTAssertEqual(stats.failedChunks, 0)
        XCTAssertEqual(stats.enqueuedBytes, replacementPayload.count)
        XCTAssertEqual(stats.sentBytes, replacementPayload.count)
        XCTAssertEqual(stats.timedOutSends, 0)
        XCTAssertEqual(stats.pendingChunks, 0)
    }

    func testLateCompletionAfterTimeoutNeverResendsChunk() async {
        typealias Completion = @Sendable (Error?) -> Void

        let payload = Data(repeating: 3, count: 2_560)
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let lateCompletion = OSAllocatedUnfairLock<Completion?>(initialState: nil)
        let sender = DeepgramFluxAudioSender(firstSendTimeout: 0.05, sendTimeout: 0.05)

        let session = sender.start { _, completion in
            invocationCount.withLock { $0 += 1 }
            lateCompletion.withLock { $0 = completion }
        }
        XCTAssertTrue(sender.enqueue(payload, session: session))

        let stats = await sender.finishAndWait(session: session, timeout: 1.0)
        lateCompletion.withLock { $0?(nil) }
        let statsAfterLateCompletion = sender.snapshot(session: session)

        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
        XCTAssertEqual(stats.enqueuedChunks, 1)
        XCTAssertEqual(stats.sentChunks, 0)
        XCTAssertEqual(stats.failedChunks, 1)
        XCTAssertEqual(stats.timedOutSends, 1)
        XCTAssertEqual(stats.pendingChunks, 0)
        XCTAssertEqual(statsAfterLateCompletion.sentChunks, 0)
        XCTAssertEqual(statsAfterLateCompletion.failedChunks, 1)
    }

    func testExplicitSendErrorFallsBackWithoutRetry() async {
        let invocationCount = OSAllocatedUnfairLock(initialState: 0)
        let sender = DeepgramFluxAudioSender(firstSendTimeout: 0.2, sendTimeout: 0.2)

        let session = sender.start { _, completion in
            invocationCount.withLock { $0 += 1 }
            completion(NSError(domain: "FluxSenderTest", code: 1))
        }
        XCTAssertTrue(sender.enqueue(Data(repeating: 4, count: 2_560), session: session))

        let stats = await sender.finishAndWait(session: session, timeout: 1.0)

        XCTAssertEqual(invocationCount.withLock { $0 }, 1)
        XCTAssertEqual(stats.sentChunks, 0)
        XCTAssertEqual(stats.failedChunks, 1)
        XCTAssertEqual(stats.timedOutSends, 0)
        XCTAssertEqual(stats.pendingChunks, 0)
    }
}
