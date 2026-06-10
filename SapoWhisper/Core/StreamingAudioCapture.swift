//
//  StreamingAudioCapture.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

struct StreamingAudioCaptureResult {
    let audioURL: URL
    let duration: TimeInterval
    let diagnostics: RecordingCaptureDiagnostics
}

final class StreamingAudioCapture: ObservableObject {
    typealias PCMChunkHandler = (Data) -> Void

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0

    var selectedDeviceUID: String = AudioDevice.systemDefault.uid

    var audioEngine: AVAudioEngine?
    var audioFile: AVAudioFile?
    var recordingURL: URL?
    var converter: AVAudioConverter?
    var converterOutputFormat: AVAudioFormat?
    var chunkHandler: PCMChunkHandler?

    var timer: Timer?
    var startTime: Date?
    var accumulatedDuration: TimeInterval = 0
    var smoothedAudioLevel: Float = 0
    var lastAudioLevelPublishTime: CFAbsoluteTime = 0
    var activeGain: Float = 1
    var converterLock = os_unfair_lock()
    var captureStateLock = os_unfair_lock()
    var startRecordingTime: CFAbsoluteTime = 0
    var firstInputBufferLogged = false
    var lastInputBufferTime: CFAbsoluteTime = 0
    var inputBufferCount = 0
    var writtenFrameCount: AVAudioFramePosition = 0
    var emittedChunkCount = 0
    var firstInputLatencyMs: Double?
    var maxInputGapMs: Double = 0
    var captureDeviceUID = AudioDevice.systemDefault.uid

    let tapBufferSize: AVAudioFrameCount = 1024
    let audioSetupQueue = DispatchQueue(label: "com.sapowhisper.streamingAudioSetup", qos: .userInitiated)
    /// A1: disk writes drain here so a slow flush never stalls the audio tap thread.
    let audioWriteQueue = DispatchQueue(label: "com.sapowhisper.streamingCapture.write", qos: .userInitiated)
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    lazy var deviceSentinel = CaptureDeviceSentinel(queue: audioSetupQueue)
    var captureRecoveryAttempts = 0
    var captureActive = false

    /// A2: called on the main thread when an interrupted capture (dead device,
    /// failed route recovery) cannot be rebuilt; the owner aborts preserving
    /// the WAV recorded so far.
    var onCaptureInterrupted: ((String) -> Void)?

    func prepareInputDeviceForRecording() -> TimeInterval {
        let deviceManager = AudioDeviceManager.shared

        guard selectedDeviceUID != AudioDevice.systemDefault.uid else {
            return deviceManager.captureRouteSettleDelay()
        }

        if deviceManager.getDeviceID(for: selectedDeviceUID) == nil {
            deviceManager.refreshDevices()
        }

        return deviceManager.getDeviceID(for: selectedDeviceUID) == nil ? 0 : deviceManager.captureRouteSettleDelay()
    }

    func startRecording(onPCMChunk: @escaping PCMChunkHandler) async throws {
        let deviceUID = selectedDeviceUID
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)

        resetCaptureDiagnostics(deviceUID: deviceUID)
        activeGain = Float(savedGain > 0 ? savedGain : 1)
        chunkHandler = onPCMChunk
        converter = nil
        converterOutputFormat = nil
        firstInputBufferLogged = false
        lastInputBufferTime = 0
        lastAudioLevelPublishTime = 0
        captureRecoveryAttempts = 0

        let result: (engine: AVAudioEngine, url: URL) = try await withCheckedThrowingContinuation { continuation in
            audioSetupQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.engineCreationFailed)
                    return
                }

                var engine: AVAudioEngine?
                var pendingURL: URL?

                do {
                    let localEngine = AVAudioEngine()
                    engine = localEngine
                    let inputNode = localEngine.inputNode
                    let hwFormat = try self.bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)
                    let tapFormat = hwFormat ?? inputNode.outputFormat(forBus: 0)

                    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                        continuation.resume(throwing: RecordingError.invalidFormat)
                        return
                    }

                    let recordingURL = TemporaryAudioStorage.makeWAVURL(prefix: "flux_recording")
                    pendingURL = recordingURL

                    let audioFile = try AVAudioFile(
                        forWriting: recordingURL,
                        settings: self.outputFormat.settings,
                        commonFormat: self.outputFormat.commonFormat,
                        interleaved: self.outputFormat.isInterleaved
                    )

                    self.audioFile = audioFile
                    self.converterOutputFormat = self.outputFormat
                    self.recordingURL = recordingURL

                    inputNode.installTap(onBus: 0, bufferSize: self.tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
                        self?.processAudioBuffer(buffer)
                    }

                    localEngine.prepare()
                    self.startRecordingTime = CFAbsoluteTimeGetCurrent()
                    try localEngine.start()
                    MicrophonePermission.noteAudioInputGranted()

                    // A2: keep the engine reachable from the setup queue and watch
                    // the bound device + engine configuration for the whole capture.
                    self.audioEngine = localEngine
                    self.setCaptureActive(true)
                    let boundDeviceID =
                        deviceUID == AudioDevice.systemDefault.uid
                        ? nil : AudioDeviceManager.shared.getDeviceID(for: deviceUID)
                    self.beginDeviceSentinel(engine: localEngine, deviceID: boundDeviceID)

                    continuation.resume(returning: (localEngine, recordingURL))
                } catch {
                    self.cleanupSetupArtifacts(engine: engine, recordingURL: pendingURL, deleteTemporaryFile: true)
                    continuation.resume(throwing: error)
                }
            }
        }

        audioEngine = result.engine
        recordingURL = result.url
        isRecording = true
        isPaused = false
        accumulatedDuration = 0
        startTime = Date()
        startTimer()
    }

    func stopRecording(logSummary: Bool = true) -> StreamingAudioCaptureResult? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        let duration = recordingDuration
        // A2: flipped before entering the queue so a sentinel event already
        // enqueued behind this stop becomes a no-op instead of a recovery.
        setCaptureActive(false)
        timer?.invalidate()
        timer = nil

        let url = audioSetupQueue.sync { () -> URL? in
            deviceSentinel.end()
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine?.reset()
            _ = flushRemainingConvertedAudio()
            // A1: drain pending async writes before releasing the file so the
            // WAV is complete when the URL is returned.
            audioWriteQueue.sync {}

            let currentURL = recordingURL
            audioFile = nil
            audioEngine = nil
            converter = nil
            converterOutputFormat = nil
            recordingURL = nil
            chunkHandler = nil
            return currentURL
        }

        isRecording = false
        isPaused = false
        let diagnostics = makeCaptureDiagnostics(fileURL: url, referenceTime: stopStart)

        if logSummary {
            SapoLog.recording.info(
                "Flux capture stopped buffers=\(diagnostics.inputBufferCount, privacy: .public) frames=\(diagnostics.writtenFrameCount, privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public)"
            )
        }

        resetPublishedState()

        guard let url else { return nil }
        return StreamingAudioCaptureResult(audioURL: url, duration: duration, diagnostics: diagnostics)
    }

    func discardRecording() {
        if let result = stopRecording(logSummary: false) {
            deleteRecording(at: result.audioURL)
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        audioEngine?.pause()
        isPaused = true
        timer?.invalidate()
        timer = nil
        if let startTime {
            accumulatedDuration += Date().timeIntervalSince(startTime)
        }
        startTime = nil
        audioLevel = 0
        smoothedAudioLevel = 0
    }

    func resumeRecording() throws {
        guard isRecording, isPaused else { return }
        try audioEngine?.start()
        MicrophonePermission.noteAudioInputGranted()
        isPaused = false
        startTime = Date()
        startTimer()
    }

    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if hasReceivedInputBuffer() { return true }
            if Task.isCancelled { return false }
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            try? await Task.sleep(nanoseconds: UInt64(max(0.01, min(0.05, remaining)) * 1_000_000_000))
        }
        return hasReceivedInputBuffer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }
    }
}
