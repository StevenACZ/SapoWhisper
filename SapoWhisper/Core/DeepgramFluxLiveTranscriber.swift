//
//  DeepgramFluxLiveTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation
import os

@MainActor
final class DeepgramFluxLiveTranscriber: ObservableObject {
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
    private var cancellables = Set<AnyCancellable>()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<String, Error>?
    /// A4 (stop race): armed the instant the CloseStream send begins — before
    /// the await, because the server can process CloseStream and emit the final
    /// EndOfTurn while this actor is still suspended inside `task.send`. With it
    /// armed, that post-close flush is recognized even if it lands before
    /// `waitForFinalTranscript` installs its continuation, instead of being
    /// dropped into the 4s timeout. Mirrors the ElevenLabs `committedCount >
    /// before` guard: armed only after `finishAndWait`/CloseStream begins, so an
    /// earlier in-speech EndOfTurn cannot short-circuit the wait.
    private var closeStreamRequested = false
    private var receivedFinalTurnAfterClose = false
    private var transcriptAccumulator = DeepgramFluxTranscriptAccumulator()
    private var lastStreamingError: Error?
    private let audioSender = DeepgramFluxAudioSender()
    private var sessionStartedAt: CFAbsoluteTime = 0
    private var stopStartedAt: CFAbsoluteTime = 0
    private var currentLanguage = "auto"

    /// Brand name surfaced in user-facing failures and logs.
    private static let engineName = "Deepgram"

    private enum StartRecovery {
        static let maxAttempts = 3
        static let firstInputTimeout: TimeInterval = 1.2
        static let retryBudget: TimeInterval = 3.0
        static let retryBackoffs: [TimeInterval] = [0.25, 0.60]
    }

    var isConfigured: Bool {
        KeychainStore.hasValue(for: .deepgramAPIKey)
    }

    init() {
        bindCapture()
    }

    func start(microphone: String, language: String) async throws {
        guard let apiKey = KeychainStore.string(for: .deepgramAPIKey),
            !apiKey.isEmpty
        else {
            throw TranscriptionFailure(kind: .notConfigured, engine: Self.engineName)
        }

        resetSessionState()
        currentLanguage = language
        let task = DeepgramFluxRequestFactory.makeWebSocketTask(apiKey: apiKey, language: language)
        webSocketTask = task
        audioSender.start(task: task)
        task.resume()
        isStreaming = true
        sessionStartedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.flux.info("Flux stream opened language=\(language, privacy: .public)")

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

    func stop() async throws -> DeepgramFluxLiveResult {
        guard isStreaming || isStopping else {
            throw TranscriptionFailure(
                kind: .unknown, engine: Self.engineName,
                technicalDetail: "Flux stream is not active")
        }

        isStopping = true
        stopStartedAt = CFAbsoluteTimeGetCurrent()
        SapoLog.flux.info("Flux stop requested")
        let captureResult = capture.stopRecording()
        isStreaming = false

        guard let captureResult else {
            cleanupWebSocket()
            throw RecordingError.fileCreationFailed
        }
        lastCaptureResult = captureResult

        guard captureResult.diagnostics.receivedInput else {
            cleanupWebSocket()
            try? FileManager.default.removeItem(at: captureResult.audioURL)
            lastCaptureResult = nil
            throw RecordingError.noInputAfterDeviceSwitch
        }

        let captureStopMs = Int((CFAbsoluteTimeGetCurrent() - stopStartedAt) * 1000)
        SapoLog.flux.info(
            "Flux local capture stopped elapsed=\(captureStopMs, privacy: .public)ms buffers=\(captureResult.diagnostics.inputBufferCount, privacy: .public) frames=\(captureResult.diagnostics.writtenFrameCount, privacy: .public) chunks=\(captureResult.diagnostics.emittedChunkCount, privacy: .public) firstInput=\(Int(captureResult.diagnostics.firstInputLatencyMs ?? -1), privacy: .public)ms lastBufferAge=\(Int(captureResult.diagnostics.lastBufferAgeMs ?? -1), privacy: .public)ms maxInputGap=\(Int(captureResult.diagnostics.maxInputGapMs), privacy: .public)ms bytes=\(captureResult.diagnostics.fileSizeBytes, privacy: .public)"
        )

        let senderStats = await audioSender.finishAndWait(timeout: 2.0)
        defer { cleanupWebSocket() }
        if senderStats.failedChunks > 0 || senderStats.pendingChunks > 0 {
            SapoLog.flux.warning(
                "Flux stream incomplete; falling back to full local audio failedChunks=\(senderStats.failedChunks, privacy: .public) pendingChunks=\(senderStats.pendingChunks, privacy: .public)"
            )
            return try await transcribeFullCaptureFallback(
                captureResult,
                reason: "sender_incomplete"
            )
        }

        let beforeCloseMs = Int((CFAbsoluteTimeGetCurrent() - stopStartedAt) * 1000)
        SapoLog.flux.info(
            "Flux sending CloseStream elapsed=\(beforeCloseMs, privacy: .public)ms sentChunks=\(senderStats.sentChunks, privacy: .public) failedChunks=\(senderStats.failedChunks, privacy: .public) pendingChunks=\(senderStats.pendingChunks, privacy: .public)"
        )
        let transcript: String
        do {
            try await sendCloseStream()
            transcript = try await waitForFinalTranscript(timeout: 4.0)
        } catch {
            SapoLog.flux.warning(
                "Flux final transcript failed reason=\(error.localizedDescription, privacy: .public); falling back to full local audio"
            )
            return try await transcribeFullCaptureFallback(
                captureResult,
                reason: "final_transcript_failed"
            )
        }
        let finalMs = Int((CFAbsoluteTimeGetCurrent() - stopStartedAt) * 1000)
        SapoLog.flux.info(
            "Flux final transcript received elapsed=\(finalMs, privacy: .public)ms characters=\(transcript.count, privacy: .public)"
        )

        let cleanedTranscript = VocabularyManager.shared
            .applyingReplacements(to: transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedTranscript.isEmpty else {
            throw TranscriptionFailure(kind: .emptyTranscription, engine: Self.engineName)
        }

        return DeepgramFluxLiveResult(
            transcript: cleanedTranscript,
            audioURL: captureResult.audioURL,
            duration: captureResult.duration,
            language: currentLanguage,
            diagnostics: captureResult.diagnostics
        )
    }

    func cancel() {
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

    private func sendCloseStream() async throws {
        guard let task = webSocketTask else { return }
        // Arm BEFORE the await: the server can process CloseStream and emit the
        // final EndOfTurn while this actor is still suspended in `task.send`, so
        // marking after the send would miss that flush. A send failure falls
        // through to the batch fallback in stop(), so arming early is safe.
        closeStreamRequested = true
        try await task.send(.string(#"{"type":"CloseStream"}"#))
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
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return
        }

        switch type {
        case "TurnInfo":
            transcriptAccumulator.update(with: json)
            // After CloseStream the server flushes a final TurnInfo with
            // event=EndOfTurn — resume immediately instead of riding the
            // stop timeout or waiting for the socket to close.
            if isStopping, (json["event"] as? String) == "EndOfTurn" {
                if closeStreamRequested { receivedFinalTurnAfterClose = true }
                finishStopIfNeeded(error: nil)
            }
        case "FatalError":
            let description = (json["description"] as? String) ?? "Unknown Flux error"
            let error = TranscriptionFailure(
                kind: .unknown, engine: Self.engineName,
                technicalDetail: "Flux FatalError: \(description)")
            lastStreamingError = error
            finishStopIfNeeded(error: error)
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
        SapoLog.flux.warning(
            "Flux receive failed while recording reason=\(error.localizedDescription, privacy: .public); keeping local audio"
        )
    }

    private func waitForFinalTranscript(timeout: TimeInterval) async throws -> String {
        if let lastStreamingError, transcriptAccumulator.transcript.isEmpty {
            throw lastStreamingError
        }

        // A4: the post-close EndOfTurn may have already landed before we got
        // here (it was dropped by finishStopIfNeeded because no continuation
        // was installed yet). Return the accumulated transcript instead of
        // riding the full timeout.
        if receivedFinalTurnAfterClose {
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

    private func transcribeFullCaptureFallback(
        _ captureResult: AudioCaptureResult,
        reason: String
    ) async throws -> DeepgramFluxLiveResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let transcript = try await DeepgramBatchTranscriber().transcribe(
            audioURL: captureResult.audioURL,
            language: currentLanguage
        )
        let cleanedTranscript = VocabularyManager.shared
            .applyingReplacements(to: transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedTranscript.isEmpty else {
            throw TranscriptionFailure(kind: .emptyTranscription, engine: Self.engineName)
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.flux.info(
            "Flux fallback transcript completed reason=\(reason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms characters=\(cleanedTranscript.count, privacy: .public) bytes=\(captureResult.diagnostics.fileSizeBytes, privacy: .public)"
        )

        return DeepgramFluxLiveResult(
            transcript: cleanedTranscript,
            audioURL: captureResult.audioURL,
            duration: captureResult.duration,
            language: currentLanguage,
            diagnostics: captureResult.diagnostics
        )
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

    private func resetSessionState() {
        transcriptAccumulator = DeepgramFluxTranscriptAccumulator()
        lastStreamingError = nil
        lastCaptureResult = nil
        isStopping = false
        closeStreamRequested = false
        receivedFinalTurnAfterClose = false
        sessionStartedAt = 0
        stopStartedAt = 0
        currentLanguage = "auto"
    }

    private func resetPublishedState() {
        isStreaming = false
        isStopping = false
        isPaused = false
        recordingDuration = 0
        audioLevel = 0
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
                        SapoLog.recording.info("Flux recovered input on attempt=\(attempt, privacy: .public)")
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
            let delayMs = Int(retryDelay * 1000)
            SapoLog.recording.info(
                "Flux input not ready attempt=\(attempt, privacy: .public) reason=\(classification.reason, privacy: .public) retryDelay=\(delayMs, privacy: .public)ms"
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
            let settleMs = Int(settleDelay * 1000)
            SapoLog.recording.info(
                "Delaying Flux capture start for route settle \(settleMs, privacy: .public)ms"
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
            "Flux attempt=\(attempt, privacy: .public) received no input buffer timeoutMs=\(Int(StartRecovery.firstInputTimeout * 1000), privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public)"
        )
        return false
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
}

// MARK: - TranscriptionEngineSession

extension DeepgramFluxLiveTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isConfigured }
    var isBusy: Bool { isStreaming || isStopping }
}
