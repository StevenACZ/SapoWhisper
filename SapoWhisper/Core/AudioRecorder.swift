//
//  AudioRecorder.swift
//  SapoWhisper
//
//

// AVFAudio's converter/tap callbacks predate Sendable annotations; buffers are
// handed off queue-to-queue under this file's own synchronization.
@preconcurrency import AVFAudio
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import OSLog
import os

/// Maneja la grabación de audio usando AVAudioEngine
///
/// Concurrency: opts out of the project's default MainActor isolation — the
/// real synchronization is `audioSetupQueue` (engine lifecycle), the tap
/// thread draining into `audioWriteQueue` (A1), and the two unfair locks for
/// converter and capture-diagnostics state. Published state is only mutated
/// on the main thread.
nonisolated class AudioRecorder: @unchecked Sendable {

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var converterOutputFormat: AVAudioFormat?

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

    private var timer: Timer?
    private var startTime: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var smoothedAudioLevel: Float = 0
    private var lastAudioLevelPublishTime: CFAbsoluteTime = 0
    private var activeGain: Float = 1.0
    private var converterLock = os_unfair_lock()
    private let tapBufferSize: AVAudioFrameCount = 1024
    private var startRecordingTime: CFAbsoluteTime = 0
    private var firstInputBufferLogged = false
    // captureStateLock-guarded: written by the tap via registerInputBuffer,
    // read by diagnostics/health-probe, reset via resetLastInputBufferTime().
    private var lastInputBufferTime: CFAbsoluteTime = 0
    private var captureStateLock = os_unfair_lock()
    private let audioSetupQueue = DispatchQueue(label: "com.sapowhisper.audioSetup", qos: .userInitiated)
    private let setupGenerationQueue = DispatchQueue(label: "com.sapowhisper.audioSetup.generation", qos: .userInitiated)
    /// A1: disk writes drain here so a slow flush never stalls the audio tap thread.
    private let audioWriteQueue = DispatchQueue(label: "com.sapowhisper.audioRecorder.write", qos: .userInitiated)
    // Used on audioSetupQueue only.
    private let deviceSentinel: CaptureDeviceSentinel
    private var captureRecoveryAttempts = 0
    private var captureHealthProbePending = false

    init() {
        deviceSentinel = CaptureDeviceSentinel(queue: audioSetupQueue)
    }

    /// A2: called on the main thread when an interrupted capture (dead device,
    /// failed route recovery) cannot be rebuilt; the owner aborts the session
    /// preserving the WAV recorded so far.
    var onCaptureInterrupted: (@Sendable (String) -> Void)?
    private var inputBufferCount = 0
    private var writtenFrameCount: AVAudioFramePosition = 0
    private var firstInputLatencyMs: Double?
    private var captureDeviceUID: String = "default"
    private var activeSetupGeneration: UInt64 = 0

    private(set) var lastCaptureDiagnostics: RecordingCaptureDiagnostics?

    /// UID del dispositivo de audio seleccionado
    var selectedDeviceUID: String = "default"

    /// Standard recording format shared by local and cloud engines.
    /// Int16 cuts file size in half vs float32 and removes an extra conversion for cloud uploads.
    private var recordingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    func prepareInputDeviceForRecording() -> TimeInterval {
        configureInputDevice()
    }

    /// Calcula el delay recomendado antes de arrancar el recorder.
    /// For selected devices we no longer rewrite the system default input; the
    /// binding happens directly on the recorder audio unit during start.
    private func configureInputDevice() -> TimeInterval {
        let deviceManager = AudioDeviceManager.shared

        guard selectedDeviceUID != "default" else {
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
    func startRecording() async throws {
        // Snapshot configuration on the calling thread before dispatching to background
        let deviceUID = selectedDeviceUID
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
        let outputFormat = recordingFormat
        let setupGeneration = beginSetupGeneration()

        // Reset per-recording state before background work begins
        converter = nil
        converterOutputFormat = nil
        resetCaptureDiagnostics()
        setCaptureDeviceUID(deviceUID)
        firstInputBufferLogged = false
        resetLastInputBufferTime()
        lastAudioLevelPublishTime = 0
        activeGain = Float(savedGain > 0 ? savedGain : 1.0)

        // Move all Core Audio HAL operations off the main thread.
        // During device transitions these calls can block 200ms–2000ms+, freezing the UI.
        typealias SetupResult = (engine: AVAudioEngine, url: URL)
        let result: SetupResult = try await withCheckedThrowingContinuation { continuation in
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
                    let inputNode = localEngine.inputNode

                    let hwFormat = try self.bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)

                    // Use actual hardware format from Core Audio to avoid stale format in inputNode.outputFormat
                    let cachedFormat = inputNode.outputFormat(forBus: 0)
                    let tapFormat: AVAudioFormat
                    if let hwFormat, hwFormat.sampleRate != cachedFormat.sampleRate {
                        tapFormat = hwFormat
                        SapoLog.recording.info(
                            "Recorder format override cachedHz=\(Int(cachedFormat.sampleRate), privacy: .public) hwHz=\(Int(hwFormat.sampleRate), privacy: .public)"
                        )
                    } else if let hwFormat {
                        tapFormat = hwFormat
                        SapoLog.recording.info(
                            "Recorder format hwHz=\(Int(hwFormat.sampleRate), privacy: .public) channels=\(hwFormat.channelCount, privacy: .public)"
                        )
                    } else {
                        tapFormat = cachedFormat
                        SapoLog.recording.info(
                            "Recorder format defaultHz=\(Int(cachedFormat.sampleRate), privacy: .public) channels=\(cachedFormat.channelCount, privacy: .public)"
                        )
                    }

                    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                        SapoLog.recording.error(
                            "Recorder setup failed: invalid sampleRate=\(tapFormat.sampleRate, privacy: .public)"
                        )
                        continuation.resume(throwing: RecordingError.invalidFormat)
                        return
                    }

                    // Crear archivo temporal para guardar el audio
                    let recordingURL = TemporaryAudioStorage.makeWAVURL(prefix: "recording")
                    pendingRecordingURL = recordingURL

                    // AVAudioFile(forWriting:settings:) always uses float32 as processing format.
                    // We need the client format to match the converted int16 buffers we write.
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

                    // Install tap with actual hardware format (queried via Core Audio, not the stale inputNode cache)
                    inputNode.installTap(onBus: 0, bufferSize: self.tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
                        self?.processAudioBuffer(buffer)
                    }

                    guard self.isSetupGenerationCurrent(setupGeneration) else {
                        self.cleanupSetupArtifacts(engine: localEngine, recordingURL: recordingURL, deleteTemporaryFile: true)
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    localEngine.prepare()
                    // Record start time just before engine.start() so the audio tap sees the correct value
                    self.startRecordingTime = CFAbsoluteTimeGetCurrent()
                    try localEngine.start()
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
                    let boundDeviceID = deviceUID == "default" ? nil : AudioDeviceManager.shared.getDeviceID(for: deviceUID)
                    self.beginDeviceSentinel(engine: localEngine, deviceID: boundDeviceID, generation: setupGeneration)

                    let setupMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    SapoLog.recording.info("Recorder setup completed in \(setupMs, privacy: .public)ms")

                    continuation.resume(returning: (localEngine, recordingURL))
                } catch {
                    self.cleanupSetupArtifacts(engine: engine, recordingURL: pendingRecordingURL, deleteTemporaryFile: true)
                    SapoLog.recording.error(
                        "Recorder setup failed error=\(error.localizedDescription, privacy: .public)"
                    )
                    continuation.resume(throwing: error)
                }
            }
        }

        guard !Task.isCancelled, isSetupGenerationCurrent(setupGeneration) else {
            cancelPendingSetup(deleteTemporaryFile: true)
            throw CancellationError()
        }

        // Back on caller context (MainActor) — update remaining instance state
        audioEngine = result.engine
        recordingURL = result.url
        isRecording = true
        isPaused = false
        accumulatedDuration = 0
        startTime = Date()

        // Timer must be scheduled on the main run loop
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }
    }

    func cancelPendingSetup(deleteTemporaryFile: Bool = true) {
        invalidateSetupGeneration()
        audioSetupQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            self.cleanupSetupArtifacts(engine: nil, recordingURL: self.recordingURL, deleteTemporaryFile: deleteTemporaryFile)
        }
    }

    /// Binds the preferred input device. Returns the device's actual hardware format if bound.
    /// Accepts `deviceUID` as a parameter so it can be called safely from a background queue
    /// without reading `self.selectedDeviceUID` across thread boundaries.
    private func bindPreferredInputDevice(to inputNode: AVAudioInputNode, deviceUID: String) throws -> AVAudioFormat? {
        guard deviceUID != "default" else { return nil }

        let deviceManager = AudioDeviceManager.shared
        guard let deviceID = deviceManager.getDeviceID(for: deviceUID) else { return nil }
        guard let audioUnit = inputNode.audioUnit else {
            throw RecordingError.deviceSelectionFailed(-1)
        }

        var currentDeviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let getStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &size
        )

        let deviceName = deviceManager.getDeviceName(for: deviceID) ?? deviceUID
        if getStatus == noErr, currentDeviceID == deviceID {
            SapoLog.recording.info(
                "Recorder input already bound device=\(deviceName, privacy: .public)"
            )
            return queryDeviceInputFormat(deviceID: deviceID)
        }

        var targetDeviceID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        guard setStatus == noErr else {
            SapoLog.recording.error(
                "Recorder bind failed device=\(deviceName, privacy: .public) status=\(setStatus, privacy: .public)"
            )
            throw RecordingError.deviceSelectionFailed(setStatus)
        }

        SapoLog.recording.info("Recorder bound input device=\(deviceName, privacy: .public)")
        return queryDeviceInputFormat(deviceID: deviceID)
    }

    /// Queries the actual hardware input format of a device via Core Audio (bypasses AVAudioEngine cache)
    private func queryDeviceInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard status == noErr else {
            SapoLog.recording.warning(
                "Recorder could not query device hw format status=\(status, privacy: .public)"
            )
            return nil
        }

        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Procesa el buffer de audio y lo escribe al archivo
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile = audioFile, let outputFormat = converterOutputFormat else { return }
        let inputBufferTime = CFAbsoluteTimeGetCurrent()
        registerInputBuffer(at: inputBufferTime)
        if !firstInputBufferLogged {
            firstInputBufferLogged = true
            let elapsed = (inputBufferTime - startRecordingTime) * 1000
            let captureDeviceUID = currentCaptureDeviceUID()
            let effectiveDevice = captureDeviceUID == "default" ? "system-default" : captureDeviceUID
            let elapsedMs = Int(elapsed)
            SapoLog.recording.info(
                "First input buffer in \(elapsedMs, privacy: .public)ms frames=\(buffer.frameLength, privacy: .public) sampleRate=\(Int(buffer.format.sampleRate), privacy: .public) input=\(effectiveDevice, privacy: .public)"
            )
        }
        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }

        // Lazy converter creation from actual buffer format (avoids stale format cache after device switch).
        // A2: rebuilt when the tap format changes mid-capture (route recovery rebinds the input).
        if converter == nil || converter?.inputFormat != buffer.format {
            let inputFmt = buffer.format
            if converter != nil {
                SapoLog.recording.info(
                    "Recorder tap format changed, rebuilding converter inHz=\(Int(inputFmt.sampleRate), privacy: .public)"
                )
            } else {
                SapoLog.recording.info(
                    "Recorder creating converter inHz=\(Int(inputFmt.sampleRate), privacy: .public) outHz=\(Int(outputFormat.sampleRate), privacy: .public)"
                )
            }
            converter = AVAudioConverter(from: inputFmt, to: outputFormat)
            if converter == nil {
                SapoLog.recording.error(
                    "Recorder converter creation failed inHz=\(Int(inputFmt.sampleRate), privacy: .public) outHz=\(Int(outputFormat.sampleRate), privacy: .public)"
                )
            }
        }
        guard let converter = converter else { return }

        let frameCapacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        var didPublishLevel = false
        // The input block runs synchronously inside convert(); the lock only
        // satisfies the Sendable contract of the SDK callback.
        let inputConsumed = OSAllocatedUnfairLock(initialState: false)

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                let alreadyConsumed = inputConsumed.withLock { (consumed: inout Bool) -> Bool in
                    if consumed { return true }
                    consumed = true
                    return false
                }
                if alreadyConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                outStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData:
                writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                didPublishLevel = true
            case .inputRanDry, .endOfStream:
                return
            case .error:
                SapoLog.recording.error(
                    "Recorder audio conversion failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return
            @unknown default:
                return
            }
        }
    }

    private func writeConvertedBuffer(_ convertedBuffer: AVAudioPCMBuffer, to audioFile: AVAudioFile, publishLevel: Bool) {
        guard convertedBuffer.frameLength > 0 else { return }

        applyGainIfNeeded(to: convertedBuffer)

        if publishLevel {
            publishAudioLevel(from: convertedBuffer)
        }

        // A1: the disk write runs on a dedicated serial queue; the converted
        // buffer is owned by this call, so handing it off is safe. The stop
        // path drains this queue before closing the file.
        audioWriteQueue.async { [weak self] in
            do {
                try audioFile.write(from: convertedBuffer)
                self?.registerWrittenFrames(convertedBuffer.frameLength)
            } catch {
                SapoLog.recording.error(
                    "Recorder audio buffer write failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Calculates and publishes recorder level from the same buffer tap used for writing.
    /// This avoids spinning up a second AVAudioEngine only for visualization.
    private func publishAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0

        if let channelData = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            for sample in samples {
                sum += sample * sample
            }
        } else if let channelData = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            for sample in samples {
                let normalized = Float(sample) / Float(Int16.max)
                sum += normalized * normalized
            }
        } else {
            return
        }

        let rms = sqrt(sum / Float(frameLength))
        let avgPower = 20 * log10(max(rms, 0.0001))
        let normalized = max(0, min(1, (avgPower + 60) / 60))

        smoothedAudioLevel = (smoothedAudioLevel * 0.7) + (normalized * 0.3)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioLevelPublishTime >= 0.05 else { return }
        lastAudioLevelPublishTime = now

        let level = smoothedAudioLevel
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }

    private func applyGainIfNeeded(to buffer: AVAudioPCMBuffer) {
        guard activeGain != 1.0 else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        if let channelData = buffer.floatChannelData {
            for i in 0..<frameCount {
                channelData[0][i] *= activeGain
            }
            return
        }

        guard let channelData = buffer.int16ChannelData else { return }
        let maxSample = Float(Int16.max)
        let minSample = Float(Int16.min)

        for i in 0..<frameCount {
            let amplified = Float(channelData[0][i]) * activeGain
            let clamped = max(minSample, min(maxSample, amplified))
            channelData[0][i] = Int16(clamped)
        }
    }

    /// Pausa la grabación manteniendo el archivo abierto
    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        audioEngine?.pause()
        isPaused = true

        // Guardar tiempo acumulado
        timer?.invalidate()
        timer = nil
        if let startTime = startTime {
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

        try audioEngine?.start()
        MicrophonePermission.noteAudioInputGranted()
        isPaused = false
        startTime = Date()
        lastAudioLevelPublishTime = 0

        // Reiniciar timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }
    }

    /// Detiene la grabación y retorna la URL del archivo
    func stopRecording(logSummary: Bool = true) -> URL? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        invalidateSetupGeneration()
        timer?.invalidate()
        timer = nil

        let url = audioSetupQueue.sync { finalizeCaptureOnQueue() }
        completeStop(url: url, stopStart: stopStart, logSummary: logSummary)
        return url
    }

    /// Variante async de `stopRecording`: el finalize (remove tap, engine
    /// stop, converter flush, file close) corre en la cola de audio sin
    /// bloquear el hilo llamador (MainActor en el stop path).
    func stopRecordingAsync(logSummary: Bool = true) async -> URL? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        invalidateSetupGeneration()
        timer?.invalidate()
        timer = nil

        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            audioSetupQueue.async { [weak self] in
                continuation.resume(returning: self?.finalizeCaptureOnQueue())
            }
        }
        completeStop(url: url, stopStart: stopStart, logSummary: logSummary)
        return url
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
        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil
        recordingURL = nil
        return currentURL
    }

    private func completeStop(url: URL?, stopStart: CFAbsoluteTime, logSummary: Bool) {
        isRecording = false
        isPaused = false

        let diagnostics = makeCaptureDiagnostics(fileURL: url, referenceTime: stopStart)
        lastCaptureDiagnostics = diagnostics
        if logSummary {
            if diagnostics.receivedInput {
                SapoLog.recording.info(
                    "Recorder stopped buffers=\(diagnostics.inputBufferCount, privacy: .public) frames=\(diagnostics.writtenFrameCount, privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public)"
                )
            } else {
                SapoLog.recording.warning(
                    "Recorder stopped without input buffers bytes=\(diagnostics.fileSizeBytes, privacy: .public) input=\(diagnostics.selectedDeviceUID, privacy: .public)"
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
    }

    func discardRecording() {
        guard isRecording || recordingURL != nil else { return }
        if let url = stopRecording(logSummary: false) {
            deleteRecording(at: url)
        }
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

    /// Flushes any delayed samples still buffered inside AVAudioConverter.
    private func flushRemainingConvertedAudio() -> (chunks: Int, frames: AVAudioFrameCount, elapsedMs: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let converter = converter,
            let outputFormat = converterOutputFormat,
            let audioFile = audioFile
        else {
            return (0, 0, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }

        let frameCapacity: AVAudioFrameCount = 4096
        var chunks = 0
        var frames: AVAudioFrameCount = 0

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
                return (chunks, frames, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            switch status {
            case .haveData:
                writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: false)
                chunks += 1
                frames += convertedBuffer.frameLength
            case .endOfStream, .inputRanDry:
                return (chunks, frames, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            case .error:
                SapoLog.recording.error(
                    "Recorder converter flush failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return (chunks, frames, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            @unknown default:
                return (chunks, frames, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
        }
    }

    /// Elimina el archivo de grabación temporal
    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func resetCaptureDiagnostics() {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }

        inputBufferCount = 0
        writtenFrameCount = 0
        firstInputLatencyMs = nil
        lastCaptureDiagnostics = nil
    }

    private func registerInputBuffer(at timestamp: CFAbsoluteTime) {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }

        lastInputBufferTime = timestamp
        inputBufferCount += 1
        if firstInputLatencyMs == nil {
            firstInputLatencyMs = (timestamp - startRecordingTime) * 1000
        }
    }

    private func registerWrittenFrames(_ frameCount: AVAudioFrameCount) {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }

        writtenFrameCount += AVAudioFramePosition(frameCount)
    }

    private func hasReceivedInputBuffer() -> Bool {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }
        return inputBufferCount > 0
    }

    private func setCaptureDeviceUID(_ uid: String) {
        os_unfair_lock_lock(&captureStateLock)
        captureDeviceUID = uid
        os_unfair_lock_unlock(&captureStateLock)
    }

    private func currentCaptureDeviceUID() -> String {
        os_unfair_lock_lock(&captureStateLock)
        let uid = captureDeviceUID
        os_unfair_lock_unlock(&captureStateLock)
        return uid
    }

    private func currentLastInputBufferTime() -> CFAbsoluteTime {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }
        return lastInputBufferTime
    }

    private func resetLastInputBufferTime() {
        os_unfair_lock_lock(&captureStateLock)
        defer { os_unfair_lock_unlock(&captureStateLock) }
        lastInputBufferTime = 0
    }

    private func makeCaptureDiagnostics(fileURL: URL?, referenceTime: CFAbsoluteTime) -> RecordingCaptureDiagnostics {
        os_unfair_lock_lock(&captureStateLock)
        let bufferCount = inputBufferCount
        let frameCount = writtenFrameCount
        let firstLatency = firstInputLatencyMs
        let deviceUID = captureDeviceUID
        let lastBuffer = lastInputBufferTime
        os_unfair_lock_unlock(&captureStateLock)

        let lastBufferAgeMs = lastBuffer > 0 ? (referenceTime - lastBuffer) * 1000 : nil
        let fileSizeBytes: Int
        if let fileURL,
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue
        {
            fileSizeBytes = size
        } else {
            fileSizeBytes = 0
        }

        return RecordingCaptureDiagnostics(
            selectedDeviceUID: deviceUID,
            inputBufferCount: bufferCount,
            writtenFrameCount: frameCount,
            emittedChunkCount: 0,
            firstInputLatencyMs: firstLatency,
            lastBufferAgeMs: lastBufferAgeMs,
            maxInputGapMs: 0,
            fileSizeBytes: fileSizeBytes
        )
    }

    private func beginSetupGeneration() -> UInt64 {
        setupGenerationQueue.sync {
            activeSetupGeneration &+= 1
            return activeSetupGeneration
        }
    }

    private func invalidateSetupGeneration() {
        setupGenerationQueue.sync {
            activeSetupGeneration &+= 1
        }
    }

    private func isSetupGenerationCurrent(_ generation: UInt64) -> Bool {
        setupGenerationQueue.sync {
            activeSetupGeneration == generation
        }
    }

    private func cleanupSetupArtifacts(engine: AVAudioEngine?, recordingURL: URL?, deleteTemporaryFile: Bool) {
        deviceSentinel.end()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }

        audioWriteQueue.sync {}
        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil

        let cleanupURL = self.recordingURL ?? recordingURL
        self.recordingURL = nil
        if deleteTemporaryFile, let cleanupURL {
            deleteRecording(at: cleanupURL)
        }
    }

    // MARK: - A2: capture interruption recovery

    private static let captureHealthProbeDelay: TimeInterval = 0.3
    private static let captureHealthyBufferMaxAge: TimeInterval = 0.5

    private func beginDeviceSentinel(engine: AVAudioEngine, deviceID: AudioDeviceID?, generation: UInt64) {
        deviceSentinel.begin(engine: engine, deviceID: deviceID) { [weak self] event in
            self?.handleCaptureInterruption(event: event, generation: generation)
        }
    }

    /// Runs on `audioSetupQueue`. A dead device rebuilds right away; a
    /// configuration change is probed first because AVAudioEngine posts it for
    /// benign renegotiations (binding a USB mic fires one right after start)
    /// while audio keeps flowing — tearing down a healthy engine re-triggers
    /// the notification until recovery is exhausted.
    private func handleCaptureInterruption(event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), audioEngine != nil else { return }

        switch event {
        case .deviceDied:
            recoverCapture(afterEvent: event, generation: generation)
        case .configurationChanged:
            scheduleCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// Coalesces configuration-change bursts into one deferred health check;
    /// the sentinel stays armed and the engine keeps running while it waits.
    private func scheduleCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard !captureHealthProbePending else { return }
        captureHealthProbePending = true
        SapoLog.recording.info("Recorder configuration changed, probing health")
        audioSetupQueue.asyncAfter(deadline: .now() + Self.captureHealthProbeDelay) { [weak self] in
            self?.runCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// Runs on `audioSetupQueue`. Leaves a healthy engine (still running,
    /// buffers still arriving) untouched and rebuilds only a dead stream.
    private func runCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        captureHealthProbePending = false
        guard isSetupGenerationCurrent(generation), let engine = audioEngine else { return }

        let lastBuffer = currentLastInputBufferTime()
        let bufferAge = CFAbsoluteTimeGetCurrent() - lastBuffer
        if engine.isRunning, lastBuffer > 0, bufferAge <= Self.captureHealthyBufferMaxAge {
            captureRecoveryAttempts = 0
            SapoLog.recording.info(
                "Recorder capture healthy after configuration change bufferAgeMs=\(Int(bufferAge * 1000), privacy: .public)"
            )
            return
        }
        recoverCapture(afterEvent: event, generation: generation)
    }

    /// Runs on `audioSetupQueue`. Rebuilds the engine after a device death or
    /// a dead post-change stream (rebinding the selected device, or falling
    /// back to the system default when it is gone). A failed rebuild reports a
    /// terminal interruption so the owner can abort preserving the WAV.
    private func recoverCapture(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), let oldEngine = audioEngine else { return }

        deviceSentinel.end()
        captureRecoveryAttempts += 1
        let attempt = captureRecoveryAttempts
        SapoLog.recording.warning(
            "Recorder capture interrupted event=\(event.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        oldEngine.reset()
        audioEngine = nil

        guard attempt <= 2 else {
            reportCaptureInterruption(reason: "\(event.rawValue) recovery-exhausted")
            return
        }

        do {
            try rebuildCaptureEngine(afterEvent: event, generation: generation)
        } catch {
            SapoLog.recording.error(
                "Recorder capture recovery failed error=\(error.localizedDescription, privacy: .public)"
            )
            reportCaptureInterruption(reason: "\(event.rawValue) rebuild-failed")
        }
    }

    private func rebuildCaptureEngine(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        var deviceUID = currentCaptureDeviceUID()
        var boundDeviceID: AudioDeviceID?
        var hwFormat: AVAudioFormat?

        if deviceUID != "default" {
            AudioDeviceManager.shared.refreshDevices()
            if event != .deviceDied,
                let format = try? bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)
            {
                hwFormat = format
                boundDeviceID = AudioDeviceManager.shared.getDeviceID(for: deviceUID)
            } else {
                // The selected device is gone: keep capturing on the system
                // default instead of recording silence for the rest of the take.
                deviceUID = "default"
                setCaptureDeviceUID(deviceUID)
                SapoLog.recording.warning("Recorder falling back to system default input")
            }
        }

        let tapFormat = hwFormat ?? inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw RecordingError.invalidFormat
        }

        // A health probe after this rebuild must see buffers from the new
        // engine, not a fresh-looking timestamp left by the dead one.
        resetLastInputBufferTime()
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        engine.prepare()
        try engine.start()

        audioEngine = engine
        beginDeviceSentinel(engine: engine, deviceID: boundDeviceID, generation: generation)
        let inputDescription = deviceUID == "default" ? "system-default" : deviceUID
        SapoLog.recording.info(
            "Recorder capture recovered input=\(inputDescription, privacy: .public) hz=\(Int(tapFormat.sampleRate), privacy: .public)"
        )
    }

    private func reportCaptureInterruption(reason: String) {
        invalidateSetupGeneration()
        let callback = onCaptureInterrupted
        DispatchQueue.main.async {
            callback?(reason)
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
