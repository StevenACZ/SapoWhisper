//
//  DeepgramFluxAudioSender.swift
//  SapoWhisper
//

import Foundation
import os

struct DeepgramFluxAudioSenderStats {
    let enqueuedChunks: Int
    let sentChunks: Int
    let failedChunks: Int
    let enqueuedBytes: Int
    let sentBytes: Int
    let maxQueueDepth: Int
    let maxSendWaitMs: Int
    let timedOutSends: Int

    var pendingChunks: Int {
        max(0, enqueuedChunks - sentChunks - failedChunks)
    }
}

final class DeepgramFluxAudioSender {
    private let queue = DispatchQueue(label: "com.sapowhisper.fluxAudioSender", qos: .userInitiated)
    private let statsLock = NSLock()
    private let stateLock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var isActive = false
    private var enqueuedChunks = 0
    private var sentChunks = 0
    private var failedChunks = 0
    private var enqueuedBytes = 0
    private var sentBytes = 0
    private var maxQueueDepth = 0
    private var maxSendWaitMs = 0
    private var timedOutSends = 0

    func start(task: URLSessionWebSocketTask) {
        resetStats()
        stateLock.lock()
        self.task = task
        isActive = true
        stateLock.unlock()
        SapoLog.flux.info("Flux audio sender started")
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        let chunkIndex = registerEnqueuedChunk(byteCount: data.count)

        queue.async { [weak self] in
            self?.send(data, chunkIndex: chunkIndex)
        }
    }

    func finishAndWait(timeout: TimeInterval) async -> DeepgramFluxAudioSenderStats {
        let startedAt = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { continuation in
            let resumeLock = NSLock()
            var didResume = false

            func resumeOnce(returning stats: DeepgramFluxAudioSenderStats) -> Bool {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !didResume else { return false }
                didResume = true
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
                        "Flux audio sender drained elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public) bytes=\(stats.sentBytes, privacy: .public) maxQueue=\(stats.maxQueueDepth, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
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
            timedOutSends: timedOutSends
        )
    }

    private func send(_ data: Data, chunkIndex: Int) {
        // One retry per chunk: a single transient send timeout must not poison
        // the session (failed chunks trigger the batch fallback upstream).
        // The serial queue keeps chunk order intact while retrying.
        for attempt in 1...2 {
            guard let task = currentTaskIfActive() else {
                registerFailedChunk()
                return
            }

            let startedAt = CFAbsoluteTimeGetCurrent()
            let semaphore = DispatchSemaphore(value: 0)
            let completionLock = NSLock()
            var sendError: Error?

            task.send(.data(data)) { error in
                completionLock.lock()
                sendError = error
                completionLock.unlock()
                semaphore.signal()
            }

            let didFinish = semaphore.wait(timeout: .now() + 2.0) == .success
            let waitMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            completionLock.lock()
            let completedError = sendError
            completionLock.unlock()

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

    private func currentTaskIfActive() -> URLSessionWebSocketTask? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return nil }
        return task
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
        stateLock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }
}

extension DeepgramFluxAudioSenderStats {
    fileprivate static let empty = DeepgramFluxAudioSenderStats(
        enqueuedChunks: 0,
        sentChunks: 0,
        failedChunks: 0,
        enqueuedBytes: 0,
        sentBytes: 0,
        maxQueueDepth: 0,
        maxSendWaitMs: 0,
        timedOutSends: 0
    )
}
