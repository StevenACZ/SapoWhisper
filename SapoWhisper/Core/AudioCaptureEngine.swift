//
//  AudioCaptureEngine.swift
//  SapoWhisper
//
//

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import OSLog
import os

/// Result of a finished capture: the WAV on disk plus what the tap saw.
struct AudioCaptureResult {
    let audioURL: URL
    let duration: TimeInterval
    let diagnostics: RecordingCaptureDiagnostics
}

/// Unified microphone capture for every engine. `.batch` records a WAV at the
/// configured `AudioUploadQuality` (MLX Whisper, hosted batch, Local AI Server);
/// `.streaming` captures fixed 16 kHz mono int16 for the WebSocket engines,
/// emitting each converted buffer as a PCM chunk while writing the same WAV as
/// the local backup. Batch is streaming with a nil chunk handler.
///
/// Concurrency: opts out of the project's default MainActor isolation — the
/// real synchronization is `audioSetupQueue` (engine lifecycle), the tap
/// thread draining into `audioWriteQueue` (A1), and the two unfair locks for
/// converter and capture-diagnostics state. Published state is only mutated
/// on the main thread.
nonisolated final class AudioCaptureEngine: @unchecked Sendable {
    typealias PCMChunkHandler = (Data) -> Void

    enum Mode {
        /// WAV at the stored `AudioUploadQuality`; no chunk emission.
        case batch
        /// Fixed 16 kHz mono int16 WAV + live PCM chunks for WebSocket engines.
        case streaming

        var wavPrefix: String {
            switch self {
            case .batch: return "recording"
            case .streaming: return "flux_recording"
            }
        }

        /// Prefix for log messages, preserving the historical greppable names.
        var logLabel: String {
            switch self {
            case .batch: return "Recorder"
            case .streaming: return "Flux"
            }
        }

        /// Prefix for `AudioEngineGuard` operation names.
        var opPrefix: String {
            switch self {
            case .batch: return "recorder"
            case .streaming: return "streaming"
            }
        }
    }

    let mode: Mode

    // Subjects instead of @Published (property wrappers cannot live in a
    // nonisolated type yet); mutated on main only, flags are read from the
    // setup queue when deciding cleanup (same pre-existing discipline).
    let isRecordingPublisher = CurrentValueSubject<Bool, Never>(false)
    let isPausedPublisher = CurrentValueSubject<Bool, Never>(false)
    let recordingDurationPublisher = CurrentValueSubject<TimeInterval, Never>(0)
    let audioLevelPublisher = CurrentValueSubject<Float, Never>(0)

    var isRecording: Bool {
        get { isRecordingPublisher.value }
        set { isRecordingPublisher.send(newValue) }
    }
    var isPaused: Bool {
        get { isPausedPublisher.value }
        set { isPausedPublisher.send(newValue) }
    }
    var recordingDuration: TimeInterval {
        get { recordingDurationPublisher.value }
        set { recordingDurationPublisher.send(newValue) }
    }
    var audioLevel: Float {
        get { audioLevelPublisher.value }
        set { audioLevelPublisher.send(newValue) }
    }

    /// UID del dispositivo de audio seleccionado
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
    let converterLock = OSAllocatedUnfairLock()
    let captureStateLock = OSAllocatedUnfairLock()
    let tapBufferSize: AVAudioFrameCount = 1024
    var startRecordingTime: CFAbsoluteTime = 0
    var firstInputBufferLogged = false
    // captureStateLock-guarded: written by the tap via registerInputBuffer(at:),
    // read by the health probe / diagnostics, reset via resetLastInputBufferTime().
    // Never write it bare off the lock (it is read from audioSetupQueue).
    var lastInputBufferTime: CFAbsoluteTime = 0
    var inputBufferCount = 0
    var writtenFrameCount: AVAudioFramePosition = 0
    var emittedChunkCount = 0
    var firstInputLatencyMs: Double?
    var maxInputGapMs: Double = 0
    var captureDeviceUID = AudioDevice.systemDefault.uid

    let audioSetupQueue = DispatchQueue(label: "com.sapowhisper.audioCapture.setup", qos: .userInitiated)
    let setupGenerationQueue = DispatchQueue(label: "com.sapowhisper.audioCapture.generation", qos: .userInitiated)
    /// A1: disk writes drain here so a slow flush never stalls the audio tap thread.
    let audioWriteQueue = DispatchQueue(label: "com.sapowhisper.audioCapture.write", qos: .userInitiated)

    static let streamingOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

    // Used on audioSetupQueue only.
    let deviceSentinel: CaptureDeviceSentinel
    var captureRecoveryAttempts = 0
    var captureHealthProbePending = false
    var activeSetupGeneration: UInt64 = 0

    private(set) var lastCaptureDiagnostics: RecordingCaptureDiagnostics?

    /// A2: called on the main thread when an interrupted capture (dead device,
    /// failed route recovery) cannot be rebuilt; the owner aborts the session
    /// preserving the WAV recorded so far.
    var onCaptureInterrupted: (@Sendable (String) -> Void)?

    init(mode: Mode) {
        self.mode = mode
        deviceSentinel = CaptureDeviceSentinel(queue: audioSetupQueue)
    }

    func prepareInputDeviceForRecording() -> TimeInterval {
        let deviceManager = AudioDeviceManager.shared

        guard selectedDeviceUID != AudioDevice.systemDefault.uid else {
            let settleDelay = deviceManager.captureRouteSettleDelay()
            logInputSettleDelayIfNeeded(settleDelay)
            return settleDelay
        }

        if deviceManager.getDeviceID(for: selectedDeviceUID) == nil {
            deviceManager.refreshDevices()
        }

        guard deviceManager.getDeviceID(for: selectedDeviceUID) != nil else {
            SapoLog.recording.warning("Selected input was missing during capture preparation")
            return 0
        }

        let settleDelay = deviceManager.captureRouteSettleDelay()
        logInputSettleDelayIfNeeded(settleDelay)
        return settleDelay
    }

    private func logInputSettleDelayIfNeeded(_ delay: TimeInterval) {
        guard delay > 0 else { return }
        let delayMs = Int(delay * 1000)
        SapoLog.recording.info("Waiting \(delayMs, privacy: .public)ms for input route to settle")
    }

    /// Inicia la grabación de audio. Toda la configuración del HAL de Core Audio se ejecuta
    /// en `audioSetupQueue` para no bloquear el hilo principal durante transiciones de dispositivo.
    /// `targetEngine` (solo batch) permite capturar directo a 16 kHz para los
    /// engines whisper-family en vez de resamplear dos veces.
    func startRecording(targetEngine: TranscriptionEngine? = nil, onPCMChunk: PCMChunkHandler? = nil) async throws {
        assert(onPCMChunk == nil || mode == .streaming, "chunk emission is a streaming-mode capability")

        // Snapshot configuration on the calling thread before dispatching to background
        let deviceUID = selectedDeviceUID
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
        let uploadQuality = AudioUploadQuality.stored()
        let setupGeneration = beginSetupGeneration()

        // Reset per-recording state before background work begins
        converter = nil
        converterOutputFormat = nil
        chunkHandler = onPCMChunk
        resetCaptureDiagnostics(deviceUID: deviceUID)
        lastCaptureDiagnostics = nil
        firstInputBufferLogged = false
        resetLastInputBufferTime()
        lastAudioLevelPublishTime = 0
        activeGain = Float(savedGain > 0 ? savedGain : 1)

        // Move all Core Audio HAL operations off the main thread. During device
        // transitions these calls can block 200ms–2000ms+, freezing the UI.
        // A4: engine/file/url are assigned ONCE inside audioSetupQueue below; the
        // continuation returns Void so the caller never re-writes those reference
        // vars off-queue (that off-queue write raced recoverCapture on the queue).
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSetupQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: RecordingError.engineCreationFailed)
                    return
                }

                var engine: AVAudioEngine?
                var pendingRecordingURL: URL?

                do {
                    let t0 = CFAbsoluteTimeGetCurrent()

                    let localEngine = AVAudioEngine()
                    engine = localEngine
                    // AudioEngineGuard: AVFAudio asserts with uncatchable
                    // NSException when the route changes under it (AirPods
                    // handshake); the guard turns that into a transient error
                    // the start-retry path already knows how to recover from.
                    let inputNode = try AudioEngineGuard.inputNode(
                        of: localEngine, operation: "\(self.mode.opPrefix)-input-node")

                    let hwFormat = try self.bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)

                    // Use actual hardware format from Core Audio to avoid stale format in inputNode.outputFormat
                    let cachedFormat = inputNode.outputFormat(forBus: 0)
                    let tapFormat: AVAudioFormat
                    if let hwFormat, hwFormat.sampleRate != cachedFormat.sampleRate {
                        tapFormat = hwFormat
                        SapoLog.recording.info(
                            "\(self.mode.logLabel, privacy: .public) format override cachedHz=\(Int(cachedFormat.sampleRate), privacy: .public) hwHz=\(Int(hwFormat.sampleRate), privacy: .public)"
                        )
                    } else if let hwFormat {
                        tapFormat = hwFormat
                        SapoLog.recording.info(
                            "\(self.mode.logLabel, privacy: .public) format hwHz=\(Int(hwFormat.sampleRate), privacy: .public) channels=\(hwFormat.channelCount, privacy: .public)"
                        )
                    } else {
                        tapFormat = cachedFormat
                        SapoLog.recording.info(
                            "\(self.mode.logLabel, privacy: .public) format defaultHz=\(Int(cachedFormat.sampleRate), privacy: .public) channels=\(cachedFormat.channelCount, privacy: .public)"
                        )
                    }

                    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                        SapoLog.recording.error(
                            "\(self.mode.logLabel, privacy: .public) setup failed: invalid sampleRate=\(tapFormat.sampleRate, privacy: .public)"
                        )
                        continuation.resume(throwing: RecordingError.invalidFormat)
                        return
                    }

                    let outputFormat: AVAudioFormat
                    switch self.mode {
                    case .batch:
                        outputFormat = uploadQuality.audioFormat(matching: tapFormat, for: targetEngine)
                        SapoLog.recording.info(
                            "Recorder upload quality=\(uploadQuality.rawValue, privacy: .public) outHz=\(Int(outputFormat.sampleRate), privacy: .public) format=\(String(describing: outputFormat.commonFormat), privacy: .public)"
                        )
                    case .streaming:
                        outputFormat = Self.streamingOutputFormat
                    }

                    // Crear archivo temporal para guardar el audio
                    let recordingURL = TemporaryAudioStorage.makeWAVURL(prefix: self.mode.wavPrefix)
                    pendingRecordingURL = recordingURL

                    // AVAudioFile(forWriting:settings:) always uses float32 as processing format.
                    // We need the client format to match the converted buffers we write.
                    let audioFile = try AVAudioFile(
                        forWriting: recordingURL,
                        settings: outputFormat.settings,
                        commonFormat: outputFormat.commonFormat,
                        interleaved: outputFormat.isInterleaved
                    )

                    guard self.isSetupGenerationCurrent(setupGeneration) else {
                        self.cleanupSetupArtifacts(engine: localEngine, recordingURL: recordingURL, deleteTemporaryFile: true)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    self.audioFile = audioFile
                    self.converterOutputFormat = outputFormat
                    self.recordingURL = recordingURL
                    // Sidecar marker: lets a relaunch after crash/force-quit
                    // recover this WAV instantly instead of after the 60 s
                    // orphan age gate.
                    ActiveRecordingMarker.mark(recordingURL)

                    // Install tap with actual hardware format (queried via Core Audio, not the stale inputNode cache)
                    try AudioEngineGuard.installTap(
                        on: inputNode, bufferSize: self.tapBufferSize, format: tapFormat,
                        operation: "\(self.mode.opPrefix)-install-tap"
                    ) { [weak self] buffer, _ in
                        self?.processAudioBuffer(buffer)
                    }

                    guard self.isSetupGenerationCurrent(setupGeneration) else {
                        self.cleanupSetupArtifacts(engine: localEngine, recordingURL: recordingURL, deleteTemporaryFile: true)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    // Record start time just before engine.start() so the audio tap sees the correct value
                    self.startRecordingTime = CFAbsoluteTimeGetCurrent()
                    try AudioEngineGuard.prepareAndStart(localEngine, operation: "\(self.mode.opPrefix)-engine-start")
                    MicrophonePermission.noteAudioInputGranted()

                    guard self.isSetupGenerationCurrent(setupGeneration) else {
                        self.cleanupSetupArtifacts(engine: localEngine, recordingURL: recordingURL, deleteTemporaryFile: true)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    // A2: keep the engine reachable from the setup queue and watch
                    // the bound device + engine configuration for the whole capture.
                    self.audioEngine = localEngine
                    self.captureRecoveryAttempts = 0
                    let boundDeviceID =
                        deviceUID == AudioDevice.systemDefault.uid
                        ? nil : AudioDeviceManager.shared.getDeviceID(for: deviceUID)
                    self.beginDeviceSentinel(engine: localEngine, deviceID: boundDeviceID, generation: setupGeneration)

                    let setupMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    SapoLog.recording.info(
                        "\(self.mode.logLabel, privacy: .public) setup completed in \(setupMs, privacy: .public)ms")

                    continuation.resume(returning: ())
                } catch {
                    self.cleanupSetupArtifacts(engine: engine, recordingURL: pendingRecordingURL, deleteTemporaryFile: true)
                    SapoLog.recording.error(
                        "\(self.mode.logLabel, privacy: .public) setup failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }

        guard !Task.isCancelled, isSetupGenerationCurrent(setupGeneration) else {
            cancelPendingSetup(deleteTemporaryFile: true)
            throw CancellationError()
        }

        // Back on caller context (MainActor) — flip published state only; the
        // engine/file/url references were assigned on the setup queue (A4).
        isRecording = true
        isPaused = false
        accumulatedDuration = 0
        startTime = Date()
        startTimer()
    }

    func cancelPendingSetup(deleteTemporaryFile: Bool = true) {
        invalidateSetupGeneration()
        audioSetupQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            self.cleanupSetupArtifacts(engine: nil, recordingURL: self.recordingURL, deleteTemporaryFile: deleteTemporaryFile)
        }
    }

    /// Detiene la grabación y retorna el WAV con su duración y diagnóstico.
    func stopRecording(logSummary: Bool = true) -> AudioCaptureResult? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        let duration = recordingDuration
        invalidateSetupGeneration()
        timer?.invalidate()
        timer = nil

        let url = audioSetupQueue.sync { finalizeCaptureOnQueue() }
        let diagnostics = completeStop(url: url, stopStart: stopStart, logSummary: logSummary)
        guard let url else { return nil }
        return AudioCaptureResult(audioURL: url, duration: duration, diagnostics: diagnostics)
    }

    /// Variante async de `stopRecording`: el finalize (remove tap, engine
    /// stop, converter flush, file close) corre en la cola de audio sin
    /// bloquear el hilo llamador (MainActor en el stop path).
    func stopRecordingAsync(logSummary: Bool = true) async -> AudioCaptureResult? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        let duration = recordingDuration
        invalidateSetupGeneration()
        timer?.invalidate()
        timer = nil

        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            audioSetupQueue.async { [weak self] in
                continuation.resume(returning: self?.finalizeCaptureOnQueue())
            }
        }
        let diagnostics = completeStop(url: url, stopStart: stopStart, logSummary: logSummary)
        guard let url else { return nil }
        return AudioCaptureResult(audioURL: url, duration: duration, diagnostics: diagnostics)
    }

    /// Must run on `audioSetupQueue`.
    private func finalizeCaptureOnQueue() -> URL? {
        deviceSentinel.end()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine?.reset()

        _ = flushRemainingConvertedAudio()
        // A1: drain pending async writes before releasing the file so the WAV
        // is complete when the URL is returned.
        audioWriteQueue.sync {}

        let currentURL = recordingURL
        if let currentURL {
            ActiveRecordingMarker.clear(currentURL)
        }
        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil
        recordingURL = nil
        chunkHandler = nil
        return currentURL
    }

    private func completeStop(url: URL?, stopStart: CFAbsoluteTime, logSummary: Bool) -> RecordingCaptureDiagnostics {
        isRecording = false
        isPaused = false

        let diagnostics = makeCaptureDiagnostics(fileURL: url, referenceTime: stopStart)
        lastCaptureDiagnostics = diagnostics
        if logSummary {
            if diagnostics.receivedInput {
                SapoLog.recording.info(
                    "\(self.mode.logLabel, privacy: .public) stopped buffers=\(diagnostics.inputBufferCount, privacy: .public) frames=\(diagnostics.writtenFrameCount, privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public)"
                )
            } else {
                SapoLog.recording.warning(
                    "\(self.mode.logLabel, privacy: .public) stopped without input buffers bytes=\(diagnostics.fileSizeBytes, privacy: .public) input=\(diagnostics.selectedDeviceUID, privacy: .public)"
                )
            }
        }

        recordingDuration = 0
        startTime = nil
        accumulatedDuration = 0
        audioLevel = 0
        smoothedAudioLevel = 0
        lastAudioLevelPublishTime = 0
        startRecordingTime = 0
        firstInputBufferLogged = false
        resetLastInputBufferTime()
        return diagnostics
    }

    func discardRecording() {
        guard isRecording || recordingURL != nil else { return }
        if let result = stopRecording(logSummary: false) {
            deleteRecording(at: result.audioURL)
        }
    }

    /// Pausa la grabación manteniendo el archivo abierto
    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        // A4: engine lifecycle stays on audioSetupQueue (like start/stop) so a
        // pause never races a concurrent recoverCapture rebuilding the engine
        // on that queue.
        audioSetupQueue.sync { audioEngine?.pause() }
        isPaused = true

        // Guardar tiempo acumulado
        timer?.invalidate()
        timer = nil
        if let startTime {
            accumulatedDuration += Date().timeIntervalSince(startTime)
        }
        startTime = nil
        audioLevel = 0
        smoothedAudioLevel = 0
        lastAudioLevelPublishTime = 0
    }

    /// Reanuda la grabación después de una pausa
    func resumeRecording() throws {
        guard isRecording, isPaused else { return }

        // A4: engine lifecycle stays on audioSetupQueue (see pauseRecording),
        // and the start goes through AudioEngineGuard — AVFAudio can assert
        // with an uncatchable NSException if the route changed while paused.
        try audioSetupQueue.sync {
            guard let engine = audioEngine else { return }
            try AudioEngineGuard.run("\(mode.opPrefix)-resume-engine-start") { try engine.start() }
        }
        MicrophonePermission.noteAudioInputGranted()
        isPaused = false
        startTime = Date()
        lastAudioLevelPublishTime = 0
        startTimer()
    }

    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            if hasReceivedInputBuffer() {
                return true
            }

            if Task.isCancelled {
                return false
            }

            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            let sleepInterval = max(0.01, min(0.05, remaining))
            try? await Task.sleep(nanoseconds: UInt64(sleepInterval * 1_000_000_000))
        }

        return hasReceivedInputBuffer()
    }

    func currentCaptureDiagnostics() -> RecordingCaptureDiagnostics {
        makeCaptureDiagnostics(fileURL: recordingURL, referenceTime: CFAbsoluteTimeGetCurrent())
    }

    /// Elimina el archivo de grabación temporal
    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startTimer() {
        // Timer must be scheduled on the main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }
    }

    // MARK: - Setup generation

    func beginSetupGeneration() -> UInt64 {
        setupGenerationQueue.sync {
            activeSetupGeneration &+= 1
            return activeSetupGeneration
        }
    }

    func invalidateSetupGeneration() {
        setupGenerationQueue.sync {
            activeSetupGeneration &+= 1
        }
    }

    func isSetupGenerationCurrent(_ generation: UInt64) -> Bool {
        setupGenerationQueue.sync {
            activeSetupGeneration == generation
        }
    }
}

nonisolated struct RecordingCaptureDiagnostics {
    let selectedDeviceUID: String
    let inputBufferCount: Int
    let writtenFrameCount: AVAudioFramePosition
    let emittedChunkCount: Int
    let firstInputLatencyMs: Double?
    let lastBufferAgeMs: Double?
    let maxInputGapMs: Double
    let fileSizeBytes: Int

    var receivedInput: Bool {
        inputBufferCount > 0 && writtenFrameCount > 0
    }
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case engineCreationFailed
    case fileCreationFailed
    case converterCreationFailed
    case permissionDenied
    case deviceSelectionFailed(OSStatus)
    case noInputAfterDeviceSwitch
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "No se pudo crear el motor de audio"
        case .fileCreationFailed:
            return "No se pudo crear el archivo de grabación"
        case .converterCreationFailed:
            return "No se pudo crear el conversor de audio"
        case .permissionDenied:
            return "Permiso de micrófono denegado"
        case .deviceSelectionFailed:
            return "No se pudo seleccionar el microfono configurado"
        case .noInputAfterDeviceSwitch:
            return "error.input_not_ready".localized
        case .invalidFormat:
            return "Formato de audio del dispositivo no disponible. Intenta de nuevo."
        }
    }
}

struct RecordingStartFailureClassification {
    let isTransient: Bool
    let reason: String
}

func classifyRecordingStartFailure(_ error: Error, routeTransitionActive: Bool) -> RecordingStartFailureClassification {
    if error is CancellationError {
        return RecordingStartFailureClassification(isTransient: false, reason: "cancelled")
    }

    // A caught AVFAudio NSException means the hardware format/HAL state moved
    // under the engine mid-setup — the signature of an in-flight route change
    // even when the transition window has already elapsed. Always retry.
    if let objcException = error as? AudioEngineObjCException {
        return RecordingStartFailureClassification(
            isTransient: true,
            reason: "objc-exception(\(objcException.operation))"
        )
    }

    if let recordingError = error as? RecordingError {
        switch recordingError {
        case .invalidFormat, .noInputAfterDeviceSwitch:
            return RecordingStartFailureClassification(isTransient: true, reason: "\(recordingError)")
        case .deviceSelectionFailed(let status):
            let transientStatuses: Set<OSStatus> = [
                kAudioUnitErr_FailedInitialization,
                kAudioUnitErr_InvalidElement,
                kAudioUnitErr_CannotDoInCurrentContext,
            ]
            let isTransient = routeTransitionActive && transientStatuses.contains(status)
            return RecordingStartFailureClassification(
                isTransient: isTransient,
                reason: "deviceSelectionFailed(\(status))"
            )
        case .engineCreationFailed, .fileCreationFailed, .converterCreationFailed, .permissionDenied:
            return RecordingStartFailureClassification(isTransient: false, reason: "\(recordingError)")
        }
    }

    let nsError = error as NSError
    let errorDescription = "\(error)"
    let userInfoDescription = nsError.userInfo.values.map { "\($0)" }.joined(separator: " ")

    let transientCodes: Set<Int> = [
        Int(kAudioUnitErr_FailedInitialization),
        Int(kAudioUnitErr_InvalidElement),
        Int(kAudioUnitErr_CannotDoInCurrentContext),
    ]

    if transientCodes.contains(nsError.code) {
        return RecordingStartFailureClassification(
            isTransient: routeTransitionActive,
            reason: "osstatus(\(nsError.code))"
        )
    }

    if errorDescription.contains("outputHWFormat")
        || errorDescription.contains("IsFormatSampleRateAndChannelCountValid")
        || userInfoDescription.contains("outputHWFormat")
        || userInfoDescription.contains("IsFormatSampleRateAndChannelCountValid")
    {
        return RecordingStartFailureClassification(isTransient: true, reason: "outputHWFormat invalid")
    }

    return RecordingStartFailureClassification(
        isTransient: false,
        reason: nsError.domain.isEmpty ? errorDescription : "\(nsError.domain)(\(nsError.code))"
    )
}
