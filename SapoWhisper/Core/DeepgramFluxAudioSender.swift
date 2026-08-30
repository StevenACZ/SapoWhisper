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

nonisolated final class DeepgramFluxAudioSender: @unchecked Sendable {
    typealias SendOperation = @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void

    private static let targetChunkBytes = 2560

    fileprivate final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let task: URLSessionWebSocketTask?
        let sendOperation: SendOperation
        let statsLock = NSLock()
        let pendingAudioLock = NSLock()

        var pendingAudio: [UInt8] = []
        var acceptingAudio = true
        var isActive = true
        var enqueuedChunks = 0
        var sentChunks = 0
        var failedChunks = 0
        var enqueuedBytes = 0
        var sentBytes = 0
        var maxQueueDepth = 0
        var maxSendWaitMs = 0
        var timedOutSends = 0
        var rejectedChunks = 0
        var rejectedBytes = 0

        init(id: UInt64, task: URLSessionWebSocketTask?, sendOperation: @escaping SendOperation) {
            queue = DispatchQueue(label: "com.sapowhisper.fluxAudioSender.\(id)", qos: .userInitiated)
            self.task = task
            self.sendOperation = sendOperation
        }
    }

    struct SessionHandle: @unchecked Sendable {
        fileprivate let session: Session
    }

    private let stateLock = NSLock()
    private let firstSendTimeout: TimeInterval
    private let subsequentSendTimeout: TimeInterval
    private var currentSession: Session?
    private var nextSessionID: UInt64 = 0

    init(firstSendTimeout: TimeInterval = 8.0, sendTimeout: TimeInterval = 2.0) {
        self.firstSendTimeout = firstSendTimeout
        subsequentSendTimeout = sendTimeout
    }

    @discardableResult
    func start(task: URLSessionWebSocketTask) -> SessionHandle {
        start(task: task) { data, completion in
            task.send(.data(data), completionHandler: completion)
        }
    }

    @discardableResult
    func start(send: @escaping SendOperation) -> SessionHandle {
        start(task: nil, send: send)
    }

    private func start(task: URLSessionWebSocketTask?, send: @escaping SendOperation) -> SessionHandle {
        stateLock.lock()
        nextSessionID &+= 1
        let session = Session(id: nextSessionID, task: task, sendOperation: send)
        let previousSession = currentSession
        previousSession?.isActive = false
        currentSession = session
        stateLock.unlock()

        sealPendingAudio(previousSession)
        previousSession?.task?.cancel(with: .goingAway, reason: nil)
        SapoLog.flux.info("Flux audio sender started")
        return SessionHandle(session: session)
    }

    @discardableResult
    func enqueue(_ data: Data, session handle: SessionHandle) -> Bool {
        guard !data.isEmpty else { return true }
        let session = handle.session

        session.pendingAudioLock.lock()
        guard session.acceptingAudio else {
            session.pendingAudioLock.unlock()
            registerRejectedChunk(byteCount: data.count, session: session)
            return false
        }

        session.pendingAudio.append(contentsOf: data)
        while session.pendingAudio.count >= Self.targetChunkBytes {
            let chunk = session.pendingAudio.prefix(Self.targetChunkBytes)
            session.pendingAudio.removeFirst(Self.targetChunkBytes)
            enqueueForSending(Data(chunk), session: session)
        }
        session.pendingAudioLock.unlock()
        return true
    }

    func finishAndWait(
        session handle: SessionHandle,
        timeout: TimeInterval
    ) async -> DeepgramFluxAudioSenderStats {
        let session = handle.session
        let startedAt = CFAbsoluteTimeGetCurrent()
        sealAndFlushPendingAudio(session)

        return await withCheckedContinuation { continuation in
            let resumeGate = OSAllocatedUnfairLock(initialState: false)

            @Sendable func resumeOnce(returning stats: DeepgramFluxAudioSenderStats) -> Bool {
                let claimed = resumeGate.withLock { didResume in
                    guard !didResume else { return false }
                    didResume = true
                    return true
                }
                guard claimed else { return false }
                continuation.resume(returning: stats)
                return true
            }

            session.queue.async { [weak self] in
                guard let self else {
                    _ = resumeOnce(returning: .empty)
                    return
                }

                self.setActive(false, session: session)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let stats = self.snapshot(session)
                if resumeOnce(returning: stats) {
                    SapoLog.flux.info(
                        "Flux audio sender drained elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public) rejected=\(stats.rejectedChunks, privacy: .public) bytes=\(stats.sentBytes, privacy: .public) maxQueue=\(stats.maxQueueDepth, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
                    )
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let stats = self.snapshot(session)
                guard stats.pendingChunks > 0 else { return }
                self.abortPendingSends(session)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let abortedStats = self.snapshot(session)
                if resumeOnce(returning: abortedStats) {
                    SapoLog.flux.warning(
                        "Flux audio sender timed out elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(abortedStats.enqueuedChunks, privacy: .public) sent=\(abortedStats.sentChunks, privacy: .public) failed=\(abortedStats.failedChunks, privacy: .public) pending=\(abortedStats.pendingChunks, privacy: .public) maxQueue=\(abortedStats.maxQueueDepth, privacy: .public) maxSendWait=\(abortedStats.maxSendWaitMs, privacy: .public)ms timeouts=\(abortedStats.timedOutSends, privacy: .public)"
                    )
                }
            }
        }
    }

    func cancel(session handle: SessionHandle) {
        let session = handle.session
        sealPendingAudio(session)
        abortPendingSends(session)
        let stats = snapshot(session)
        if stats.pendingChunks > 0 || stats.failedChunks > 0 {
            SapoLog.flux.info(
                "Flux audio sender cancelled enqueued=\(stats.enqueuedChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public) failed=\(stats.failedChunks, privacy: .public) pending=\(stats.pendingChunks, privacy: .public)"
            )
        }
    }

    func snapshot(session handle: SessionHandle) -> DeepgramFluxAudioSenderStats {
        snapshot(handle.session)
    }

    func sealAndFlushPendingAudio(session handle: SessionHandle) {
        sealAndFlushPendingAudio(handle.session)
    }

    private func snapshot(_ session: Session) -> DeepgramFluxAudioSenderStats {
        session.statsLock.lock()
        defer { session.statsLock.unlock() }

        return DeepgramFluxAudioSenderStats(
            enqueuedChunks: session.enqueuedChunks,
            sentChunks: session.sentChunks,
            failedChunks: session.failedChunks,
            enqueuedBytes: session.enqueuedBytes,
            sentBytes: session.sentBytes,
            maxQueueDepth: session.maxQueueDepth,
            maxSendWaitMs: session.maxSendWaitMs,
            timedOutSends: session.timedOutSends,
            rejectedChunks: session.rejectedChunks,
            rejectedBytes: session.rejectedBytes
        )
    }

    private func sealAndFlushPendingAudio(_ session: Session) {
        session.pendingAudioLock.lock()
        session.acceptingAudio = false
        let remainder = Data(session.pendingAudio)
        session.pendingAudio.removeAll(keepingCapacity: true)
        if !remainder.isEmpty {
            enqueueForSending(remainder, session: session)
        }
        session.pendingAudioLock.unlock()
    }

    private func sealPendingAudio(_ session: Session?) {
        guard let session else { return }
        session.pendingAudioLock.lock()
        session.acceptingAudio = false
        session.pendingAudio.removeAll(keepingCapacity: true)
        session.pendingAudioLock.unlock()
    }

    private func enqueueForSending(_ data: Data, session: Session) {
        let chunkIndex = registerEnqueuedChunk(byteCount: data.count, session: session)
        session.queue.async { [weak self] in
            self?.send(data, chunkIndex: chunkIndex, session: session)
        }
    }

    private func send(_ data: Data, chunkIndex: Int, session: Session) {
        guard isActive(session) else {
            registerFailedChunk(session: session)
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        let sendErrorBox = OSAllocatedUnfairLock<Error?>(initialState: nil)

        session.sendOperation(data) { error in
            sendErrorBox.withLock { $0 = error }
            semaphore.signal()
        }

        let timeout = chunkIndex == 1 ? firstSendTimeout : subsequentSendTimeout
        let didFinish = semaphore.wait(timeout: .now() + timeout) == .success
        let waitMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        let completedError = sendErrorBox.withLock { $0 }

        guard didFinish, completedError == nil, isActive(session) else {
            let reason =
                didFinish
                ? completedError.map(TranscriptionFailure.diagnosticDetail(for:)) ?? "cancelled"
                : "timeout"
            registerFailedChunk(waitMs: waitMs, timedOut: !didFinish, session: session)
            SapoLog.flux.warning(
                "Flux audio chunk send failed index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms reason=\(reason, privacy: .public)"
            )
            return
        }

        registerSentChunk(byteCount: data.count, waitMs: waitMs, session: session)
        if chunkIndex == 1 || chunkIndex % 100 == 0 || waitMs > 250 {
            let stats = snapshot(session)
            SapoLog.flux.info(
                "Flux audio chunk sent index=\(chunkIndex, privacy: .public) wait=\(waitMs, privacy: .public)ms pending=\(stats.pendingChunks, privacy: .public) sent=\(stats.sentChunks, privacy: .public)"
            )
        }
    }

    private func registerEnqueuedChunk(byteCount: Int, session: Session) -> Int {
        session.statsLock.lock()
        session.enqueuedChunks += 1
        session.enqueuedBytes += byteCount
        session.maxQueueDepth = max(
            session.maxQueueDepth,
            session.enqueuedChunks - session.sentChunks - session.failedChunks
        )
        let chunkIndex = session.enqueuedChunks
        session.statsLock.unlock()
        return chunkIndex
    }

    private func registerSentChunk(byteCount: Int, waitMs: Int, session: Session) {
        session.statsLock.lock()
        session.sentChunks += 1
        session.sentBytes += byteCount
        session.maxSendWaitMs = max(session.maxSendWaitMs, waitMs)
        session.statsLock.unlock()
    }

    private func registerFailedChunk(
        waitMs: Int = 0,
        timedOut: Bool = false,
        session: Session
    ) {
        session.statsLock.lock()
        session.failedChunks += 1
        session.maxSendWaitMs = max(session.maxSendWaitMs, waitMs)
        if timedOut {
            session.timedOutSends += 1
        }
        session.statsLock.unlock()
    }

    private func registerRejectedChunk(byteCount: Int, session: Session) {
        session.statsLock.lock()
        session.rejectedChunks += 1
        session.rejectedBytes += byteCount
        session.statsLock.unlock()
    }

    private func isActive(_ session: Session) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session.isActive
    }

    private func setActive(_ active: Bool, session: Session) {
        stateLock.lock()
        session.isActive = active
        stateLock.unlock()
    }

    private func abortPendingSends(_ session: Session) {
        setActive(false, session: session)
        session.task?.cancel(with: .goingAway, reason: nil)
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
