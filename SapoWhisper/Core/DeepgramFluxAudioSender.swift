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
        queue.sync {
            self.task = task
            self.isActive = true
        }
        resetStats()
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
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(
                        returning: DeepgramFluxAudioSenderStats(
                            enqueuedChunks: 0,
                            sentChunks: 0,
                            failedChunks: 0,
                            enqueuedBytes: 0,
                            sentBytes: 0,
                            maxQueueDepth: 0,
                            maxSendWaitMs: 0,
                            timedOutSends: 0
                        )
                    )
                    return
                }

                self.isActive = false
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let stats = self.snapshot()
                SapoLog.flux.info(
                    "Flux audio sender drained elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public) bytes=\(stats.sentBytes, privacy: .public) maxQueue=\(stats.maxQueueDepth, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
                )
                continuation.resume(returning: stats)
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let stats = self.snapshot()
                guard stats.pendingChunks > 0 else { return }
                SapoLog.flux.warning(
                    "Flux audio sender still draining after timeout pending=\(stats.pendingChunks, privacy: .public) maxQueue=\(stats.maxQueueDepth, privacy: .public)"
                )
            }
        }
    }

    func cancel() {
        queue.sync {
            isActive = false
            task = nil
        }
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
        guard isActive, let task else {
            registerFailedChunk()
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?

        task.send(.data(data)) { error in
            sendError = error
            semaphore.signal()
        }

        let didFinish = semaphore.wait(timeout: .now() + 2.0) == .success
        let waitMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

        if didFinish, sendError == nil {
            registerSentChunk(byteCount: data.count, waitMs: waitMs)
            if chunkIndex == 1 || chunkIndex % 100 == 0 || waitMs > 250 {
                let stats = snapshot()
                SapoLog.flux.info(
                    "Flux audio chunk sent index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms pending=\(stats.pendingChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public)"
                )
            }
            return
        }

        registerFailedChunk(waitMs: waitMs, timedOut: !didFinish)
        let reason = didFinish ? (sendError?.localizedDescription ?? "unknown") : "timeout"
        SapoLog.flux.warning(
            "Flux audio chunk send failed index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms reason=\(reason, privacy: .public)"
        )
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
}
