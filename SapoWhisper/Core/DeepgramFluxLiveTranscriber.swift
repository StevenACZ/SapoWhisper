//
//  DeepgramFluxLiveTranscriber.swift
//  SapoWhisper
//

import Combine
import Foundation

@MainActor
final class DeepgramFluxLiveTranscriber: ObservableObject {
    @Published private(set) var isStreaming = false
    @Published private(set) var isStopping = false
    @Published private(set) var isPaused = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    private(set) var lastCaptureResult: StreamingAudioCaptureResult?

    private let capture = StreamingAudioCapture()
    private var cancellables = Set<AnyCancellable>()
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioSendTask: Task<Void, Never>?
    private var stopTimeoutTask: Task<Void, Never>?
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var transcriptAccumulator = DeepgramFluxTranscriptAccumulator()
    private var lastStreamingError: Error?

    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? ""
        return !key.isEmpty
    }

    init() {
        bindCapture()
    }

    func start(microphone: String) async throws {
        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey),
              !apiKey.isEmpty else {
            throw DeepgramError.notConfigured
        }

        resetSessionState()
        let task = DeepgramFluxRequestFactory.makeWebSocketTask(apiKey: apiKey)
        webSocketTask = task
        task.resume()
        isStreaming = true

        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        do {
            capture.selectedDeviceUID = microphone
            let settleDelay = capture.prepareInputDeviceForRecording()
            if settleDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            }

            try await capture.startRecording { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.sendAudioChunk(data)
                }
            }

            let receivedInput = await capture.waitForFirstInputBuffer(timeout: 0.8)
            if !receivedInput {
                capture.discardRecording()
                throw RecordingError.noInputAfterDeviceSwitch
            }
        } catch {
            cancel()
            throw error
        }
    }

    func stop() async throws -> DeepgramFluxLiveResult {
        guard isStreaming || isStopping else {
            throw DeepgramError.apiError("Flux stream is not active")
        }

        isStopping = true
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

        await audioSendTask?.value
        defer { cleanupWebSocket() }
        try await sendCloseStream()
        let transcript = try await waitForFinalTranscript(timeout: 4.0)

        let cleanedTranscript = VocabularyManager.shared
            .applyingReplacements(to: transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedTranscript.isEmpty else {
            throw DeepgramError.apiError("No transcript returned")
        }

        return DeepgramFluxLiveResult(
            transcript: cleanedTranscript,
            audioURL: captureResult.audioURL,
            duration: captureResult.duration,
            language: "auto",
            diagnostics: captureResult.diagnostics
        )
    }

    func cancel() {
        capture.discardRecording()
        cleanupWebSocket()
        lastCaptureResult = nil
        resetPublishedState()
    }

    func pauseRecording() {
        capture.pauseRecording()
    }

    func resumeRecording() throws {
        try capture.resumeRecording()
    }

    private func bindCapture() {
        capture.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        capture.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        capture.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPaused in
                self?.isPaused = isPaused
            }
            .store(in: &cancellables)
    }

    private func sendAudioChunk(_ data: Data) {
        guard !data.isEmpty, isStreaming, !isStopping, let task = webSocketTask else { return }
        let previousSendTask = audioSendTask
        audioSendTask = Task { [weak self, previousSendTask] in
            await previousSendTask?.value
            guard !Task.isCancelled else { return }
            do {
                try await task.send(.data(data))
            } catch {
                self?.handleStreamingError(error)
            }
        }
    }

    private func sendCloseStream() async throws {
        guard let task = webSocketTask else { return }
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
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "TurnInfo":
            transcriptAccumulator.update(with: json)
        case "FatalError":
            let description = (json["description"] as? String) ?? "Unknown Flux error"
            let error = DeepgramError.apiError(description)
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

        if isCancellation(error) { return }
        lastStreamingError = error
        isStreaming = false
        capture.discardRecording()
    }

    private func handleStreamingError(_ error: Error) {
        guard !isStopping, !isCancellation(error) else { return }
        lastStreamingError = error
    }

    private func waitForFinalTranscript(timeout: TimeInterval) async throws -> String {
        if let lastStreamingError, transcriptAccumulator.transcript.isEmpty {
            throw lastStreamingError
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

    private func resetSessionState() {
        transcriptAccumulator = DeepgramFluxTranscriptAccumulator()
        lastStreamingError = nil
        lastCaptureResult = nil
        isStopping = false
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
        audioSendTask?.cancel()
        audioSendTask = nil
        stopTimeoutTask?.cancel()
        stopTimeoutTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        stopContinuation = nil
        resetPublishedState()
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
