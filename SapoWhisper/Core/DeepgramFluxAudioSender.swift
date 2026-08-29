//
//  DeepgramFluxAudioSender.swift
//  SapoWhisper
//

import Foundation
import os

nonisolated struct DeepgramFluxAudioSenderStats {
    let enqueuedChunks: Int
    let sentChunks: Int
    let failedChunks: Int
    let enqueuedBytes: Int
    let sentBytes: Int
    let maxQueueDepth: Int
    let maxSendWaitMs: Int
    let timedOutSends: Int
    let rejectedChunks: Int
    let rejectedBytes: Int

    var pendingChunks: Int {
        max(0, enqueuedChunks - sentChunks - failedChunks)
    }
}

/// Concurrency: nonisolated by design — chunk sends run on the serial send
/// queue, every counter sits behind `statsLock`/`stateLock`, and sub-chunk
/// audio accumulates behind `pendingAudioLock`.
nonisolated final class DeepgramFluxAudioSender: @unchecked Sendable {
    typealias SendOperation = @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void

    /// Flux strongly recommends ~80 ms audio chunks, but the capture tap
    /// emits ~21 ms blocks — coalesce to 2560 bytes (80 ms @ 16 kHz mono
    /// int16) before sending.
    private static let targetChunkBytes = 2560

    private let queue = DispatchQueue(label: "com.sapowhisper.fluxAudioSender", qos: .userInitiated)
    private let statsLock = NSLock()
    private let stateLock = NSLock()
    private let pendingAudioLock = NSLock()

    private var pendingAudio: [UInt8] = []
    private var acceptingAudio = false

    private var task: URLSessionWebSocketTask?
    private var sendOperation: SendOperation?
    private var isActive = false
    private var enqueuedChunks = 0
    private var sentChunks = 0
    private var failedChunks = 0
    private var enqueuedBytes = 0
    private var sentBytes = 0
    private var maxQueueDepth = 0
    private var maxSendWaitMs = 0
    private var timedOutSends = 0
    private var rejectedChunks = 0
    private var rejectedBytes = 0

    func start(task: URLSessionWebSocketTask) {
        start(task: task) { data, completion in
            task.send(.data(data), completionHandler: completion)
        }
    }

    func start(send: @escaping SendOperation) {
        start(task: nil, send: send)
    }

    private func start(task: URLSessionWebSocketTask?, send: @escaping SendOperation) {
        resetStats()
        pendingAudioLock.lock()
        pendingAudio.removeAll(keepingCapacity: true)
        acceptingAudio = true
        pendingAudioLock.unlock()
        stateLock.lock()
        self.task = task
        sendOperation = send
        isActive = true
        stateLock.unlock()
        SapoLog.flux.info("Flux audio sender started")
    }

    @discardableResult
    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }

        pendingAudioLock.lock()
        guard acceptingAudio else {
            pendingAudioLock.unlock()
            registerRejectedChunk(byteCount: data.count)
            return false
        }

        pendingAudio.append(contentsOf: data)
        while pendingAudio.count >= Self.targetChunkBytes {
            let chunk = pendingAudio.prefix(Self.targetChunkBytes)
            pendingAudio.removeFirst(Self.targetChunkBytes)
            enqueueForSending(Data(chunk))
        }
        pendingAudioLock.unlock()
        return true
    }

    func finishAndWait(timeout: TimeInterval) async -> DeepgramFluxAudioSenderStats {
        let startedAt = CFAbsoluteTimeGetCurrent()

        sealAndFlushPendingAudio()

        return await withCheckedContinuation { continuation in
            let resumeGate = OSAllocatedUnfairLock(initialState: false)

            @Sendable func resumeOnce(returning stats: DeepgramFluxAudioSenderStats) -> Bool {
                let claimed = resumeGate.withLock { (didResume: inout Bool) -> Bool in
                    guard !didResume else { return false }
                    didResume = true
                    return true
                }
                guard claimed else { return false }
                continuation.resume(returning: stats)
                return true
            }

            queue.async { [weak self] in
                guard let self else {
                    _ = resumeOnce(
                        returning: .empty
                    )
                    return
                }

                self.setActive(false)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let stats = self.snapshot()
                if resumeOnce(returning: stats) {
                    SapoLog.flux.info(
                        "Flux audio sender drained elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public) rejected=\(stats.rejectedChunks, privacy: .public) bytes=\(stats.sentBytes, privacy: .public) maxQueue=\(stats.maxQueueDepth, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
                    )
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let stats = self.snapshot()
                guard stats.pendingChunks > 0 else { return }
                self.abortPendingSends()
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let abortedStats = self.snapshot()
                if resumeOnce(returning: abortedStats) {
                    SapoLog.flux.warning(
                        "Flux audio sender timed out elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(abortedStats.enqueuedChunks, privacy: .public) sent=\(abortedStats.sentChunks, privacy: .public) failed=\(abortedStats.failedChunks, privacy: .public) pending=\(abortedStats.pendingChunks, privacy: .public) maxQueue=\(abortedStats.maxQueueDepth, privacy: .public) maxSendWait=\(abortedStats.maxSendWaitMs, privacy: .public)ms timeouts=\(abortedStats.timedOutSends, privacy: .public)"
                    )
                }
            }
        }
    }

    func cancel() {
        pendingAudioLock.lock()
        acceptingAudio = false
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioLock.unlock()
        abortPendingSends()
        let stats = snapshot()
        if stats.pendingChunks > 0 || stats.failedChunks > 0 {
            SapoLog.flux.info(
                "Flux audio sender cancelled enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public)"
            )
        }
    }

    func snapshot() -> DeepgramFluxAudioSenderStats {
        statsLock.lock()
        defer { statsLock.unlock() }

        return DeepgramFluxAudioSenderStats(
            enqueuedChunks: enqueuedChunks,
            sentChunks: sentChunks,
            failedChunks: failedChunks,
            enqueuedBytes: enqueuedBytes,
            sentBytes: sentBytes,
            maxQueueDepth: maxQueueDepth,
            maxSendWaitMs: maxSendWaitMs,
            timedOutSends: timedOutSends,
            rejectedChunks: rejectedChunks,
            rejectedBytes: rejectedBytes
        )
    }

    func sealAndFlushPendingAudio() {
        pendingAudioLock.lock()
        acceptingAudio = false
        let remainder = Data(pendingAudio)
        pendingAudio.removeAll(keepingCapacity: true)
        if !remainder.isEmpty {
            enqueueForSending(remainder)
        }
        pendingAudioLock.unlock()
    }

    private func enqueueForSending(_ data: Data) {
        let chunkIndex = registerEnqueuedChunk(byteCount: data.count)
        queue.async { [weak self] in
            self?.send(data, chunkIndex: chunkIndex)
        }
    }

    private func send(_ data: Data, chunkIndex: Int) {
        // One retry per chunk: a single transient send timeout must not poison
        // the session (failed chunks trigger the batch fallback upstream).
        // The serial queue keeps chunk order intact while retrying.
        for attempt in 1...2 {
            guard let sendOperation = currentSendOperationIfActive() else {
                registerFailedChunk()
                return
            }

            let startedAt = CFAbsoluteTimeGetCurrent()
            let semaphore = DispatchSemaphore(value: 0)
            let sendErrorBox = OSAllocatedUnfairLock<Error?>(initialState: nil)

            sendOperation(data) { error in
                sendErrorBox.withLock { $0 = error }
                semaphore.signal()
            }

            // The first chunk absorbs the WebSocket handshake (capture starts
            // concurrently with the connect), so give it a longer budget.
            let sendTimeout: TimeInterval = chunkIndex == 1 ? 8.0 : 2.0
            let didFinish = semaphore.wait(timeout: .now() + sendTimeout) == .success
            let waitMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            let completedError = sendErrorBox.withLock { $0 }

            if didFinish, completedError == nil {
                registerSentChunk(byteCount: data.count, waitMs: waitMs)
                if chunkIndex == 1 || chunkIndex % 100 == 0 || waitMs > 250 || attempt > 1 {
                    let stats = snapshot()
                    SapoLog.flux.info(
                        "Flux audio chunk sent index=\(chunkIndex, privacy: .public) attempt=\(attempt, privacy: .public) wait=\(waitMs, privacy: .public)ms pending=\(stats.pendingChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public)"
                    )
                }
                return
            }

            let reason = didFinish ? (completedError?.localizedDescription ?? "unknown") : "timeout"
            if attempt == 1 {
                SapoLog.flux.warning(
                    "Flux audio chunk send retrying index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms reason=\(reason, privacy: .public)"
                )
                continue
            }

            registerFailedChunk(waitMs: waitMs, timedOut: !didFinish)
            SapoLog.flux.warning(
                "Flux audio chunk send failed index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms reason=\(reason, privacy: .public)"
            )
        }
    }

    private func resetStats() {
        statsLock.lock()
        enqueuedChunks = 0
        sentChunks = 0
        failedChunks = 0
        enqueuedBytes = 0
        sentBytes = 0
        maxQueueDepth = 0
        maxSendWaitMs = 0
        timedOutSends = 0
        rejectedChunks = 0
        rejectedBytes = 0
        statsLock.unlock()
    }

    private func registerEnqueuedChunk(byteCount: Int) -> Int {
        statsLock.lock()
        enqueuedChunks += 1
        enqueuedBytes += byteCount
        maxQueueDepth = max(maxQueueDepth, enqueuedChunks - sentChunks - failedChunks)
        let chunkIndex = enqueuedChunks
        statsLock.unlock()
        return chunkIndex
    }

    private func registerSentChunk(byteCount: Int, waitMs: Int) {
        statsLock.lock()
        sentChunks += 1
        sentBytes += byteCount
        maxSendWaitMs = max(maxSendWaitMs, waitMs)
        statsLock.unlock()
    }

    private func registerFailedChunk(waitMs: Int = 0, timedOut: Bool = false) {
        statsLock.lock()
        failedChunks += 1
        maxSendWaitMs = max(maxSendWaitMs, waitMs)
        if timedOut {
            timedOutSends += 1
        }
        statsLock.unlock()
    }

    private func registerRejectedChunk(byteCount: Int) {
        statsLock.lock()
        rejectedChunks += 1
        rejectedBytes += byteCount
        statsLock.unlock()
    }

    private func currentSendOperationIfActive() -> SendOperation? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return nil }
        return sendOperation
    }

    private func setActive(_ active: Bool) {
        stateLock.lock()
        isActive = active
        stateLock.unlock()
    }

    private func abortPendingSends() {
        stateLock.lock()
        isActive = false
        let task = task
        self.task = nil
        sendOperation = nil
        stateLock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }
}

nonisolated extension DeepgramFluxAudioSenderStats {
    fileprivate static let empty = DeepgramFluxAudioSenderStats(
        enqueuedChunks: 0,
        sentChunks: 0,
        failedChunks: 0,
        enqueuedBytes: 0,
        sentBytes: 0,
        maxQueueDepth: 0,
        maxSendWaitMs: 0,
        timedOutSends: 0,
        rejectedChunks: 0,
        rejectedBytes: 0
    )
}
