//
//  ElevenLabsScribeRealtimeTranscriber.swift
//  SapoWhisper
//

@preconcurrency import AVFAudio
import AVFoundation
import Combine
import Foundation
import os

struct ElevenLabsRealtimeAudioSenderStats {
    let enqueuedChunks: Int
    let sentMessages: Int
    let failedMessages: Int
    let enqueuedBytes: Int
    let sentAudioBytes: Int
    let maxBufferedBytes: Int
    let maxSendWaitMs: Int
    let timedOutSends: Int
    /// Sends still in flight when the drain deadline cancelled the socket.
    /// They never reach `failedMessages`, so the counters alone look healthy.
    var drainTimedOut: Bool = false

    var pendingChunks: Int {
        max(0, enqueuedChunks - sentMessages - failedMessages)
    }
}

struct ElevenLabsRealtimeTranscriptAccumulator {
    private(set) var latestPartial: String = ""
    private(set) var committedSegments: [String] = []
    private(set) var sessionID: String?

    var committedCount: Int { committedSegments.count }
    var hasUncommittedPartial: Bool { !latestPartial.isEmpty }

    mutating func recordSessionStarted(_ id: String?) {
        sessionID = id
    }

    mutating func recordPartial(_ text: String?) {
        latestPartial = sanitized(text)
    }

    mutating func recordCommitted(_ text: String?) {
        let committed = sanitized(text)
        guard !committed.isEmpty else { return }
        if committedSegments.last != committed {
            committedSegments.append(committed)
        }
        latestPartial = ""
    }

    var transcript: String {
        committedSegments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitized(_ text: String?) -> String {
        (text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Concurrency: nonisolated by design — audio batching runs on the serial
/// send queue and every counter sits behind `statsLock`/`stateLock`.
nonisolated final class ElevenLabsRealtimeAudioSender: @unchecked Sendable {
    private enum Constants {
        static let sampleRate = 16000
        static let targetChunkBytes = 6_400  // 0.2s of pcm_16000 mono int16.
        static let finalSilenceBytes = 6_400
        static let sendTimeout: TimeInterval = 2.0
        static let firstSendTimeout: TimeInterval = 8.0
    }

    private let queue = DispatchQueue(label: "com.sapowhisper.elevenlabsRealtimeAudioSender", qos: .userInitiated)
    private let statsLock = NSLock()
    private let stateLock = NSLock()
    private let pendingAudioLock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var isActive = false
    private var generation = 0
    private var hasUsedFirstSendBudget = false
    private var pendingAudio: [UInt8] = []
    private var enqueuedChunks = 0
    private var sentMessages = 0
    private var failedMessages = 0
    private var enqueuedBytes = 0
    private var sentAudioBytes = 0
    private var maxBufferedBytes = 0
    private var maxSendWaitMs = 0
    private var timedOutSends = 0

    func start(task: URLSessionWebSocketTask) {
        reset()
        stateLock.lock()
        self.task = task
        isActive = true
        generation &+= 1
        stateLock.unlock()
        SapoLog.recording.info("ElevenLabs realtime audio sender started")
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let activeGeneration = currentGenerationIfActive() else {
            registerFailedMessage()
            return
        }
        registerEnqueuedChunk(byteCount: data.count)

        queue.async { [weak self] in
            self?.appendAndFlushIfNeeded(data, generation: activeGeneration)
        }
    }

    func finishAndCommit(timeout: TimeInterval) async -> ElevenLabsRealtimeAudioSenderStats {
        let startedAt = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { continuation in
            let resumeGate = OSAllocatedUnfairLock(initialState: false)

            @Sendable func resumeOnce(returning stats: ElevenLabsRealtimeAudioSenderStats) -> Bool {
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
                    _ = resumeOnce(returning: .empty)
                    return
                }
                guard let activeGeneration = self.currentGenerationIfActive() else {
                    _ = resumeOnce(returning: self.snapshot())
                    return
                }

                self.flushFinalCommit(generation: activeGeneration)
                self.deactivate(generation: activeGeneration)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                let stats = self.snapshot()
                if resumeOnce(returning: stats) {
                    SapoLog.recording.info(
                        "ElevenLabs realtime audio sender drained elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sentMessages=\(stats.sentMessages, privacy: .public) failedMessages=\(stats.failedMessages, privacy: .public) sentBytes=\(stats.sentAudioBytes, privacy: .public) maxBuffered=\(stats.maxBufferedBytes, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
                    )
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                var stats = self.snapshot()
                stats.drainTimedOut = true
                if resumeOnce(returning: stats) {
                    self.abortPendingSends()
                    SapoLog.recording.warning(
                        "ElevenLabs realtime audio sender timed out elapsed=\(elapsedMs, privacy: .public)ms enqueued=\(stats.enqueuedChunks, privacy: .public) sentMessages=\(stats.sentMessages, privacy: .public) failedMessages=\(stats.failedMessages, privacy: .public) maxBuffered=\(stats.maxBufferedBytes, privacy: .public) maxSendWait=\(stats.maxSendWaitMs, privacy: .public)ms timeouts=\(stats.timedOutSends, privacy: .public)"
                    )
                }
            }
        }
    }

    func cancel() {
        abortPendingSends()
        let stats = snapshot()
        if stats.sentMessages > 0 || stats.failedMessages > 0 {
            SapoLog.recording.info(
                "ElevenLabs realtime audio sender cancelled sentMessages=\(stats.sentMessages, privacy: .public) failedMessages=\(stats.failedMessages, privacy: .public)"
            )
        }
    }

    func snapshot() -> ElevenLabsRealtimeAudioSenderStats {
        statsLock.lock()
        defer { statsLock.unlock() }

        return ElevenLabsRealtimeAudioSenderStats(
            enqueuedChunks: enqueuedChunks,
            sentMessages: sentMessages,
            failedMessages: failedMessages,
            enqueuedBytes: enqueuedBytes,
            sentAudioBytes: sentAudioBytes,
            maxBufferedBytes: maxBufferedBytes,
            maxSendWaitMs: maxSendWaitMs,
            timedOutSends: timedOutSends
        )
    }

    private func appendAndFlushIfNeeded(_ data: Data, generation: Int) {
        guard currentTaskIfActive(generation: generation) != nil else {
            registerFailedMessage()
            return
        }

        var chunks: [Data] = []
        var bufferedBytes = 0
        pendingAudioLock.lock()
        pendingAudio.append(contentsOf: data)
        bufferedBytes = pendingAudio.count

        while pendingAudio.count >= Constants.targetChunkBytes {
            let chunk = pendingAudio.prefix(Constants.targetChunkBytes)
            pendingAudio.removeFirst(Constants.targetChunkBytes)
            chunks.append(Data(chunk))
        }
        pendingAudioLock.unlock()

        registerBufferedBytes(bufferedBytes)
        for chunk in chunks {
            sendAudioChunk(chunk, commit: false, generation: generation)
        }
    }

    private func flushFinalCommit(generation: Int) {
        guard currentTaskIfActive(generation: generation) != nil else {
            registerFailedMessage()
            return
        }

        pendingAudioLock.lock()
        var finalAudio = Data(pendingAudio)
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioLock.unlock()

        // A short silence tail gives the realtime service a clean boundary to finalize.
        finalAudio.append(Data(repeating: 0, count: Constants.finalSilenceBytes))
        sendAudioChunk(finalAudio, commit: true, generation: generation)
    }

    private func sendAudioChunk(_ data: Data, commit: Bool, generation: Int) {
        guard !data.isEmpty else { return }
        guard let task = currentTaskIfActive(generation: generation) else {
            registerFailedMessage()
            return
        }

        let message: String
        do {
            message = try makeChunkMessage(audioData: data, commit: commit)
        } catch {
            registerFailedMessage()
            SapoLog.recording.error("ElevenLabs realtime chunk encode failed")
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        let sendErrorBox = OSAllocatedUnfairLock<Error?>(initialState: nil)

        task.send(.string(message)) { error in
            sendErrorBox.withLock { $0 = error }
            semaphore.signal()
        }

        // The first message absorbs the WebSocket handshake (capture starts
        // concurrently with the connect), so give it a longer budget.
        let sendTimeout = consumeFirstSendBudgetIfNeeded() ?? Constants.sendTimeout
        let didFinish = semaphore.wait(timeout: .now() + sendTimeout) == .success
        let waitMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        let completedError = sendErrorBox.withLock { $0 }

        if didFinish, completedError == nil {
            registerSentMessage(byteCount: data.count, waitMs: waitMs)
            if commit || waitMs > 250 {
                SapoLog.recording.info(
                    "ElevenLabs realtime audio chunk sent commit=\(commit, privacy: .public) bytes=\(data.count, privacy: .public) wait=\(waitMs, privacy: .public)ms"
                )
            }
            return
        }

        registerFailedMessage(waitMs: waitMs, timedOut: !didFinish)
        let reason =
            didFinish
            ? completedError.map { LogSanitizer.errorDiagnostic($0, state: "realtime-send") }
                ?? "state=realtime-send domain=none code=0"
            : "state=realtime-send domain=timeout code=0"
        SapoLog.recording.warning(
            "ElevenLabs realtime audio chunk send failed commit=\(commit, privacy: .public) wait=\(waitMs, privacy: .public)ms reason=\(reason, privacy: .public)"
        )
    }

    private func makeChunkMessage(audioData: Data, commit: Bool) throws -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audioData.base64EncodedString(),
            "sample_rate": Constants.sampleRate,
            "commit": commit,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TranscriptionFailure(
                kind: .unknown,
                engine: "ElevenLabs",
                technicalDetail: "could not encode realtime chunk JSON"
            )
        }
        return text
    }

    /// Returns the extended handshake budget exactly once per session.
    private func consumeFirstSendBudgetIfNeeded() -> TimeInterval? {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard !hasUsedFirstSendBudget else { return nil }
        hasUsedFirstSendBudget = true
        return Constants.firstSendTimeout
    }

    private func reset() {
        pendingAudioLock.lock()
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioLock.unlock()

        statsLock.lock()
        hasUsedFirstSendBudget = false
        enqueuedChunks = 0
        sentMessages = 0
        failedMessages = 0
        enqueuedBytes = 0
        sentAudioBytes = 0
        maxBufferedBytes = 0
        maxSendWaitMs = 0
        timedOutSends = 0
        statsLock.unlock()
    }

    private func registerEnqueuedChunk(byteCount: Int) {
        statsLock.lock()
        enqueuedChunks += 1
        enqueuedBytes += byteCount
        statsLock.unlock()
    }

    private func registerBufferedBytes(_ count: Int) {
        statsLock.lock()
        maxBufferedBytes = max(maxBufferedBytes, count)
        statsLock.unlock()
    }

    private func registerSentMessage(byteCount: Int, waitMs: Int) {
        statsLock.lock()
        sentMessages += 1
        sentAudioBytes += byteCount
        maxSendWaitMs = max(maxSendWaitMs, waitMs)
        statsLock.unlock()
    }

    private func registerFailedMessage(waitMs: Int = 0, timedOut: Bool = false) {
        statsLock.lock()
        failedMessages += 1
        maxSendWaitMs = max(maxSendWaitMs, waitMs)
        if timedOut {
            timedOutSends += 1
        }
        statsLock.unlock()
    }

    private func currentGenerationIfActive() -> Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive else { return nil }
        return generation
    }

    private func currentTaskIfActive(generation expectedGeneration: Int) -> URLSessionWebSocketTask? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isActive, generation == expectedGeneration else { return nil }
        return task
    }

    private func deactivate(generation expectedGeneration: Int) {
        stateLock.lock()
        if generation == expectedGeneration {
            isActive = false
        }
        stateLock.unlock()
    }

    private func abortPendingSends() {
        stateLock.lock()
        let task = self.task
        self.task = nil
        isActive = false
        generation &+= 1
        stateLock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }
}

@MainActor
final class ElevenLabsScribeRealtimeTranscriber: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var isStopping = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0

    private(set) var lastCaptureResult: AudioCaptureResult?

    /// A2: fired on the main thread when the local capture died mid-session
    /// and could not be recovered; the owner aborts preserving the WAV.
    var onCaptureInterrupted: ((String) -> Void)?

    private let capture = AudioCaptureEngine(mode: .streaming)
    private let audioSender = ElevenLabsRealtimeAudioSender()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var transcriptAccumulator = ElevenLabsRealtimeTranscriptAccumulator()
    private var lastStreamingError: Error?
    private var cancellables = Set<AnyCancellable>()
    private var stopStartedAt: CFAbsoluteTime = 0
    private var requestedLanguage = "auto"

    nonisolated private static let engineName = "ElevenLabs"
    private static let maxRealtimeKeyterms = ElevenLabsKeytermLimits.realtimeMaxCount
    private static let maxRealtimeKeytermLength = ElevenLabsKeytermLimits.realtimeMaxLength
    nonisolated private static let sampleRate = 16000

    private enum StartRecovery {
        static let maxAttempts = 3
        static let firstInputTimeout: TimeInterval = 1.2
        static let retryBudget: TimeInterval = 3.0
        static let retryBackoffs: [TimeInterval] = [0.25, 0.60]
    }

    var isConfigured: Bool {
        KeychainStore.hasValue(for: .elevenLabsAPIKey)
    }

    static func recognitionKeytermPayload(
        from vocabularyManager: VocabularyManager
    ) -> (terms: [String], droppedCount: Int) {
        vocabularyManager.recognitionKeytermPayload(
            maxCount: Self.maxRealtimeKeyterms,
            maxLength: Self.maxRealtimeKeytermLength
        )
    }

    init() {
        bindCapture()
    }

    func start(microphone: String, language: String) async throws {
        guard let apiKey = KeychainStore.string(for: .elevenLabsAPIKey),
            !apiKey.isEmpty
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        resetSessionState()
        requestedLanguage = language
        let keytermPayload = Self.recognitionKeytermPayload(from: .shared)
        let keyterms = keytermPayload.terms
        let task = Self.makeWebSocketTask(apiKey: apiKey, language: language, keyterms: keyterms)
        webSocketTask = task
        audioSender.start(task: task)
        task.resume()
        isStreaming = true
        SapoLog.recording.info(
            "ElevenLabs realtime stream opened keyterms=\(keyterms.count, privacy: .public) keytermsDropped=\(keytermPayload.droppedCount, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-realtime-opened",
            context: "language=\(language) keyterms=\(keyterms.count) keytermsDropped=\(keytermPayload.droppedCount)",
            force: true
        )

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        do {
            try await startCaptureWithRecovery(microphone: microphone)
        } catch {
            cancel()
            throw error
        }
    }

    func stop(
        onCaptureStopped: @escaping @MainActor @Sendable () -> Void
    ) async throws -> StreamingDictationResult {
        guard isStreaming || isStopping else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName,
                technicalDetail: "ElevenLabs realtime stream is not active"
            )
        }

        isStopping = true
        stopStartedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.recording.info("ElevenLabs realtime stop requested")
        let captureResult = StopCaptureHandoff.perform(
            seal: { capture.stopRecording() },
            onStopped: onCaptureStopped
        )
        isStreaming = false

        guard let captureResult else {
            cleanupWebSocket()
            throw RecordingError.fileCreationFailed
        }
        lastCaptureResult = captureResult

        guard captureResult.diagnostics.receivedInput else {
            cleanupWebSocket()
            capture.deleteRecording(at: captureResult.audioURL)
            lastCaptureResult = nil
            throw RecordingError.noInputAfterDeviceSwitch
        }

        let captureStopMs = Int((CFAbsoluteTimeGetCurrent() - stopStartedAt) * 1000)
        SapoLog.recording.info(
            "ElevenLabs realtime local capture stopped elapsed=\(captureStopMs, privacy: .public)ms buffers=\(captureResult.diagnostics.inputBufferCount, privacy: .public) frames=\(captureResult.diagnostics.writtenFrameCount, privacy: .public) chunks=\(captureResult.diagnostics.emittedChunkCount, privacy: .public) bytes=\(captureResult.diagnostics.fileSizeBytes, privacy: .public)"
        )

        let committedCountBeforeFinalCommit = transcriptAccumulator.committedCount
        let hadUncommittedPartialBeforeFinalCommit = transcriptAccumulator.hasUncommittedPartial
        let senderStats = await audioSender.finishAndCommit(timeout: 2.0)
        defer { cleanupWebSocket() }

        // Degraded stream: chunks never reached the server, so the realtime
        // transcript is missing audio the local WAV still has. Re-transcribe
        // the full take through the batch endpoint (same pattern as the Flux
        // fallback); a failed fallback falls through so waitForFinalTranscript
        // still salvages whatever the server already committed.
        if Self.shouldFallBackToBatch(senderStats: senderStats) {
            SapoLog.recording.warning(
                "ElevenLabs realtime sender incomplete failedMessages=\(senderStats.failedMessages, privacy: .public) timedOut=\(senderStats.timedOutSends, privacy: .public) drainTimedOut=\(senderStats.drainTimedOut, privacy: .public); falling back to batch transcription"
            )
            do {
                return try await transcribeFullCaptureFallback(captureResult, reason: "sender_incomplete")
            } catch {
                let detail = LogSanitizer.errorDiagnostic(error, state: "realtime-batch-fallback")
                guard !transcriptAccumulator.transcript.isEmpty else {
                    throw TranscriptionFailure(
                        kind: .network,
                        engine: Self.engineName,
                        technicalDetail:
                            "ElevenLabs realtime sender failedMessages=\(senderStats.failedMessages) timedOut=\(senderStats.timedOutSends) drainTimedOut=\(senderStats.drainTimedOut); \(detail)"
                    )
                }
                SapoLog.recording.warning(
                    "ElevenLabs realtime batch fallback failed \(detail, privacy: .public); salvaging committed segments"
                )
            }
        }

        let finalWaitStartedAt = CFAbsoluteTimeGetCurrent()
        let finalWaitTimeout: TimeInterval
        if committedCountBeforeFinalCommit == 0 && !hadUncommittedPartialBeforeFinalCommit {
            // Zero partials and zero commits: VAD never fired, so nothing is
            // coming — fail fast instead of riding the 4s wait. The local WAV
            // is preserved either way.
            finalWaitTimeout = 0.5
        } else if committedCountBeforeFinalCommit == 0 || hadUncommittedPartialBeforeFinalCommit {
            finalWaitTimeout = 4.0
        } else {
            finalWaitTimeout = 0.75
        }
        let transcript: String
        do {
            transcript = try await waitForFinalTranscript(
                timeout: finalWaitTimeout,
                committedCountBeforeFinalCommit: committedCountBeforeFinalCommit
            )
        } catch {
            // The stream died without committing anything usable; the local
            // WAV still has the take, so batch it instead of losing the words.
            let detail = LogSanitizer.errorDiagnostic(error, state: "realtime-final")
            SapoLog.recording.warning(
                "ElevenLabs realtime final transcript failed \(detail, privacy: .public); falling back to batch transcription"
            )
            return try await transcribeFullCaptureFallback(captureResult, reason: "final_transcript_failed")
        }
        let salvagedTranscript = salvagingPendingPartial(
            transcript,
            committedCountBeforeFinalCommit: committedCountBeforeFinalCommit
        )
        let finalWaitMs = Int((CFAbsoluteTimeGetCurrent() - finalWaitStartedAt) * 1000)
        let stopElapsedMs = Int((CFAbsoluteTimeGetCurrent() - stopStartedAt) * 1000)

        let cleanedTranscript = VocabularyManager.shared
            .applyingRecognitionCorrections(to: salvagedTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        SapoLog.recording.info(
            "ElevenLabs realtime final transcript sessionID=\(self.transcriptAccumulator.sessionID ?? "n/a", privacy: .public) elapsed=\(stopElapsedMs, privacy: .public)ms finalWait=\(finalWaitMs, privacy: .public)ms committed=\(self.transcriptAccumulator.committedCount, privacy: .public) enqueuedChunks=\(senderStats.enqueuedChunks, privacy: .public) sentMessages=\(senderStats.sentMessages, privacy: .public) chars=\(cleanedTranscript.count, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "elevenlabs-realtime-finished",
            context:
                "sessionID=\(transcriptAccumulator.sessionID ?? "n/a") elapsedMs=\(stopElapsedMs) finalWaitMs=\(finalWaitMs) committed=\(transcriptAccumulator.committedCount) enqueuedChunks=\(senderStats.enqueuedChunks) sentMessages=\(senderStats.sentMessages) sentAudioBytes=\(senderStats.sentAudioBytes) audioBytes=\(captureResult.diagnostics.fileSizeBytes) chars=\(cleanedTranscript.count)",
            force: true
        )

        guard !cleanedTranscript.isEmpty else {
            // The realtime session produced nothing while the WAV has audio
            // (VAD never fired, final commit lost): batch the take before
            // surfacing an empty transcription.
            return try await transcribeFullCaptureFallback(captureResult, reason: "empty_realtime_transcript")
        }

        return StreamingDictationResult(
            transcript: cleanedTranscript,
            audioURL: captureResult.audioURL,
            duration: captureResult.duration,
            language: requestedLanguage,
            diagnostics: captureResult.diagnostics
        )
    }

    /// `pendingChunks` is deliberately not a signal here: `enqueuedChunks`
    /// counts capture callbacks while `sentMessages` counts 6400-byte
    /// messages, so their difference is noise.
    nonisolated static func shouldFallBackToBatch(senderStats: ElevenLabsRealtimeAudioSenderStats) -> Bool {
        senderStats.failedMessages > 0 || senderStats.drainTimedOut
    }

    /// Batch fallback for a degraded realtime session (mirrors
    /// `DeepgramFluxLiveTranscriber.transcribeFullCaptureFallback`): the local
    /// WAV holds the complete take, so re-transcribing it through the Scribe
    /// batch endpoint recovers words the stream lost. The batch transcriber
    /// reads the same Keychain API key and already applies vocabulary
    /// corrections and the empty-transcript guard.
    private func transcribeFullCaptureFallback(
        _ captureResult: AudioCaptureResult,
        reason: String
    ) async throws -> StreamingDictationResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let transcript = try await ElevenLabsScribeTranscriber().transcribe(
            audioURL: captureResult.audioURL,
            language: requestedLanguage
        )

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.recording.info(
            "ElevenLabs realtime fallback transcript completed reason=\(reason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms chars=\(transcript.count, privacy: .public) bytes=\(captureResult.diagnostics.fileSizeBytes, privacy: .public)"
        )

        return StreamingDictationResult(
            transcript: transcript,
            audioURL: captureResult.audioURL,
            duration: captureResult.duration,
            language: requestedLanguage,
            diagnostics: captureResult.diagnostics
        )
    }

    /// The final commit can outlive the stop wait; when it never arrived, the
    /// pending partial still holds the tail of the dictation — append it
    /// instead of silently truncating the take.
    private func salvagingPendingPartial(
        _ transcript: String,
        committedCountBeforeFinalCommit: Int
    ) -> String {
        guard transcriptAccumulator.committedCount == committedCountBeforeFinalCommit,
            transcriptAccumulator.hasUncommittedPartial
        else { return transcript }

        let pendingPartial = transcriptAccumulator.latestPartial
        SapoLog.recording.warning(
            "ElevenLabs realtime final commit missing; appending pending partial chars=\(pendingPartial.count, privacy: .public)"
        )
        return transcript.isEmpty ? pendingPartial : "\(transcript) \(pendingPartial)"
    }

    // File transcription (retry, history, resume-merge) always routes to the
    // batch endpoint — the old WebSocket replay path was dead code and is gone.

    func cancel() {
        capture.cancelPendingSetup()
        capture.discardRecording()
        cleanupWebSocket()
        lastCaptureResult = nil
        resetPublishedState()
    }

    /// Stops the local capture and tears down the socket without any network
    /// wait. Used on system sleep; the WAV is preserved for manual retry.
    func abortPreservingAudio() -> AudioCaptureResult? {
        let captureResult = capture.stopRecording(logSummary: false)
        cleanupWebSocket()
        lastCaptureResult = nil
        resetPublishedState()
        return captureResult
    }

    func pauseRecording() {
        capture.pauseRecording()
    }

    func resumeRecording() throws {
        try capture.resumeRecording()
    }

    private static func makeWebSocketTask(apiKey: String, language: String, keyterms: [String]) -> URLSessionWebSocketTask {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.elevenlabs.io"
        components.path = "/v1/speech-to-text/realtime"
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.5"),
            URLQueryItem(name: "vad_threshold", value: "0.4"),
        ]

        if let languageCode = scribeLanguageCode(for: language) {
            components.queryItems?.append(URLQueryItem(name: "language_code", value: languageCode))
        }

        components.queryItems?.append(contentsOf: keyterms.map { URLQueryItem(name: "keyterms", value: $0) })

        guard let url = components.url else {
            preconditionFailure("Invalid ElevenLabs realtime URL")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        return URLSession.shared.webSocketTask(with: request)
    }

    private static func scribeLanguageCode(for appLanguage: String) -> String? {
        TranscriptionLanguageCatalog.elevenLabsLanguageCode(for: appLanguage)
    }

    private func bindCapture() {
        // A2: a capture that died mid-session (device gone, recovery failed)
        // bubbles up so the owner can abort preserving the WAV. The capture
        // always delivers this callback on the main queue.
        capture.onCaptureInterrupted = { [weak self] reason in
            MainActor.assumeIsolated {
                self?.onCaptureInterrupted?(reason)
            }
        }

        capture.recordingDurationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        capture.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        capture.isPausedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPaused in
                self?.isPaused = isPaused
            }
            .store(in: &cancellables)
    }

    private func startCaptureWithRecovery(microphone: String) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + StartRecovery.retryBudget
        var lastFailure: Error = RecordingError.noInputAfterDeviceSwitch

        for attempt in 1...StartRecovery.maxAttempts {
            guard !Task.isCancelled else { throw CancellationError() }

            do {
                let didStart = try await attemptCaptureStart(
                    microphone: microphone,
                    attempt: attempt,
                    minimumDelay: attempt == 1 ? 0 : StartRecovery.retryBackoffs[attempt - 2]
                )
                if didStart {
                    if attempt > 1 {
                        SapoLog.recording.info("ElevenLabs realtime recovered input on attempt=\(attempt, privacy: .public)")
                    }
                    return
                }
                lastFailure = RecordingError.noInputAfterDeviceSwitch
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastFailure = error
            }

            capture.discardRecording()
            guard attempt < StartRecovery.maxAttempts else { break }

            let routeTransitionActive = AudioDeviceManager.shared.captureRouteSettleDelay() > 0
            let classification = classifyRecordingStartFailure(lastFailure, routeTransitionActive: routeTransitionActive)
            guard classification.isTransient else {
                throw lastFailure
            }

            let remainingBudget = deadline - CFAbsoluteTimeGetCurrent()
            guard remainingBudget > 0 else { break }

            let retryDelay = min(
                remainingBudget,
                max(StartRecovery.retryBackoffs[attempt - 1], AudioDeviceManager.shared.captureRouteSettleDelay())
            )
            SapoLog.recording.info(
                "ElevenLabs realtime input not ready attempt=\(attempt, privacy: .public) reason=\(classification.reason, privacy: .public) retryDelay=\(Int(retryDelay * 1000), privacy: .public)ms"
            )
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }

        throw lastFailure
    }

    private func attemptCaptureStart(
        microphone: String,
        attempt: Int,
        minimumDelay: TimeInterval
    ) async throws -> Bool {
        capture.selectedDeviceUID = microphone
        let settleDelay = max(minimumDelay, capture.prepareInputDeviceForRecording())
        if settleDelay > 0 {
            SapoLog.recording.info(
                "Delaying ElevenLabs realtime capture start for route settle \(Int(settleDelay * 1000), privacy: .public)ms"
            )
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }

        guard !Task.isCancelled else { throw CancellationError() }
        let audioSender = self.audioSender
        try await capture.startRecording { data in
            audioSender.enqueue(data)
        }

        let receivedInput = await capture.waitForFirstInputBuffer(timeout: StartRecovery.firstInputTimeout)
        if receivedInput {
            return true
        }

        let diagnostics = capture.currentCaptureDiagnostics()
        SapoLog.recording.warning(
            "ElevenLabs realtime attempt=\(attempt, privacy: .public) received no input buffer timeoutMs=\(Int(StartRecovery.firstInputTimeout * 1000), privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public)"
        )
        return false
    }

    private func receiveMessages() async {
        guard let task = webSocketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                handleMessage(message)
            }
        } catch {
            handleReceiveCompletion(error)
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleJSONMessage(text)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { return }
            handleJSONMessage(text)
        @unknown default:
            break
        }
    }

    private func handleJSONMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        let type = (json["message_type"] as? String) ?? (json["type"] as? String) ?? ""
        switch type {
        case "session_started":
            let sessionID = json["session_id"] as? String
            transcriptAccumulator.recordSessionStarted(sessionID)
            SapoLog.recording.info(
                "ElevenLabs realtime session started sessionID=\(sessionID ?? "n/a", privacy: .public)"
            )
        case "partial_transcript":
            transcriptAccumulator.recordPartial(json["text"] as? String)
        case "committed_transcript", "committed_transcript_with_timestamps":
            let previousCount = transcriptAccumulator.committedCount
            transcriptAccumulator.recordCommitted(json["text"] as? String)
            if transcriptAccumulator.committedCount > previousCount {
                SapoLog.recording.info(
                    "ElevenLabs realtime committed segment count=\(self.transcriptAccumulator.committedCount, privacy: .public)"
                )
                finishStopIfNeeded(error: nil)
            }
        case "auth_error", "quota_exceeded", "rate_limited", "commit_throttled", "queue_overflow", "resource_exhausted",
            "session_time_limit_exceeded", "chunk_size_exceeded", "input_error", "transcriber_error",
            "unaccepted_terms", "error":
            let failure = failure(forRealtimeError: type, payload: json)
            lastStreamingError = failure
            finishStopIfNeeded(error: failure)
        default:
            break
        }
    }

    private func handleReceiveCompletion(_ error: Error) {
        if isStopping {
            finishStopIfNeeded(error: nil)
            return
        }

        if !isStreaming || isCancellation(error) { return }
        lastStreamingError = error
        let detail = LogSanitizer.errorDiagnostic(error, state: "realtime-receive")
        SapoLog.recording.warning(
            "ElevenLabs realtime receive failed while recording \(detail, privacy: .public); keeping local audio"
        )
    }

    private func waitForFinalTranscript(
        timeout: TimeInterval,
        committedCountBeforeFinalCommit: Int
    ) async throws -> String {
        if let lastStreamingError, transcriptAccumulator.transcript.isEmpty {
            throw lastStreamingError
        }

        if transcriptAccumulator.committedCount > committedCountBeforeFinalCommit {
            return transcriptAccumulator.transcript
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            stopTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finishStopIfNeeded(error: nil)
            }
        }
    }

    private func finishStopIfNeeded(error: Error?) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil

        let transcript = transcriptAccumulator.transcript
        if let error, transcript.isEmpty {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: transcript)
        }
    }

    private func failure(forRealtimeError type: String, payload: [String: Any]) -> TranscriptionFailure {
        let detailText =
            (payload["message"] as? String)
            ?? (payload["detail"] as? String)
            ?? (payload["error"] as? String)
            ?? type
        let detail = "ElevenLabs realtime \(type): \(detailText.prefix(300))"

        let kind: TranscriptionFailure.Kind
        switch type {
        case "auth_error":
            kind = .auth
        case "quota_exceeded":
            kind = .outOfCredits
        case "rate_limited", "commit_throttled":
            kind = .rateLimited
        case "queue_overflow", "resource_exhausted", "error":
            kind = .serverError
        case "session_time_limit_exceeded":
            kind = .timedOut
        case "chunk_size_exceeded", "input_error":
            kind = .audioCorrupt
        case "unaccepted_terms":
            kind = .planRestricted
        default:
            kind = .unknown
        }

        return TranscriptionFailure(kind: kind, engine: Self.engineName, technicalDetail: detail)
    }

    private func resetSessionState() {
        transcriptAccumulator = ElevenLabsRealtimeTranscriptAccumulator()
        lastStreamingError = nil
        lastCaptureResult = nil
        isStopping = false
        stopStartedAt = 0
    }

    private func resetPublishedState() {
        isStreaming = false
        isStopping = false
        isPaused = false
        recordingDuration = 0
        audioLevel = 0
    }

    private func cleanupWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil
        audioSender.cancel()
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        // Resume (not just drop) a pending stop continuation: abandoning a
        // CheckedContinuation leaks it, warns under strict concurrency, and
        // suspends the awaiting stop() forever. finishStopIfNeeded() nils before
        // resuming and both run on the MainActor, so this does not double-resume.
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        resetPublishedState()
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated static func extractPCM16MonoData(from wavURL: URL) throws -> Data {
        let inputFile = try AVAudioFile(forReading: wavURL)
        let inputFormat = inputFile.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TranscriptionFailure(kind: .audioCorrupt, engine: Self.engineName, technicalDetail: "invalid WAV format")
        }

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw TranscriptionFailure(
                kind: .audioCorrupt,
                engine: Self.engineName,
                technicalDetail: "could not create pcm_16000 converter"
            )
        }
        // Mastering-grade sample rate conversion: the default SRC's
        // anti-aliasing is mediocre for the 48k→16k hop.
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let inputFrames = AVAudioFrameCount(inputFile.length)
        guard inputFrames > 0,
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrames)
        else {
            throw TranscriptionFailure(kind: .audioCorrupt, engine: Self.engineName, technicalDetail: "empty WAV input")
        }
        do {
            try inputFile.read(into: inputBuffer)
        } catch {
            throw TranscriptionFailure.from(error, engine: Self.engineName)
        }

        let estimatedFrames = Int(ceil(Double(inputFrames) * outputFormat.sampleRate / inputFormat.sampleRate))
        let outputCapacity = AVAudioFrameCount(max(1024, estimatedFrames + 512))
        var pcmData = Data()
        pcmData.reserveCapacity(max(0, estimatedFrames) * MemoryLayout<Int16>.size)

        let inputConsumed = OSAllocatedUnfairLock(initialState: false)

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw TranscriptionFailure(
                    kind: .audioCorrupt,
                    engine: Self.engineName,
                    technicalDetail: "could not allocate pcm_16000 buffer"
                )
            }

            var convertError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
                let alreadyConsumed = inputConsumed.withLock { (consumed: inout Bool) -> Bool in
                    if consumed { return true }
                    consumed = true
                    return false
                }
                if alreadyConsumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return inputBuffer
            }

            appendPCM16(from: outputBuffer, to: &pcmData)

            switch status {
            case .haveData, .inputRanDry:
                continue
            case .endOfStream:
                guard !pcmData.isEmpty else {
                    throw TranscriptionFailure(kind: .audioCorrupt, engine: Self.engineName, technicalDetail: "empty pcm_16000 output")
                }
                return pcmData
            case .error:
                let detail =
                    convertError.map { LogSanitizer.errorDiagnostic($0, state: "pcm-convert") }
                    ?? "state=pcm-convert domain=none code=0"
                throw TranscriptionFailure(
                    kind: .audioCorrupt,
                    engine: Self.engineName,
                    technicalDetail: detail
                )
            @unknown default:
                throw TranscriptionFailure(kind: .audioCorrupt, engine: Self.engineName)
            }
        }
    }

    private nonisolated static func appendPCM16(from buffer: AVAudioPCMBuffer, to data: inout Data) {
        guard buffer.frameLength > 0, let channelData = buffer.int16ChannelData else { return }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        data.append(contentsOf: UnsafeRawBufferPointer(start: channelData[0], count: byteCount))
    }
}

nonisolated extension ElevenLabsRealtimeAudioSenderStats {
    fileprivate static let empty = ElevenLabsRealtimeAudioSenderStats(
        enqueuedChunks: 0,
        sentMessages: 0,
        failedMessages: 0,
        enqueuedBytes: 0,
        sentAudioBytes: 0,
        maxBufferedBytes: 0,
        maxSendWaitMs: 0,
        timedOutSends: 0
    )
}

// MARK: - TranscriptionEngineSession

extension ElevenLabsScribeRealtimeTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isConfigured }
    var isBusy: Bool { isStreaming || isStopping }
}

// MARK: - StreamingDictationSession

extension ElevenLabsScribeRealtimeTranscriber: StreamingDictationSession {
    var isStreamingPublisher: AnyPublisher<Bool, Never> { $isStreaming.eraseToAnyPublisher() }
    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> { $recordingDuration.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { $audioLevel.eraseToAnyPublisher() }
}
