//
//  AudioRecorder.swift
//  SapoWhisper
//
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine
import OSLog
import os

/// Maneja la grabación de audio usando AVAudioEngine
class AudioRecorder: ObservableObject {

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var converter: AVAudioConverter?
    private var converterOutputFormat: AVAudioFormat?

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioLevel: Float = 0.0

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
    private var lastInputBufferTime: CFAbsoluteTime = 0
    private var captureStateLock = os_unfair_lock()
    private let audioSetupQueue = DispatchQueue(label: "com.sapowhisper.audioSetup", qos: .userInitiated)
    private let setupGenerationQueue = DispatchQueue(label: "com.sapowhisper.audioSetup.generation", qos: .userInitiated)
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
            print("⚠️ [capture] selected input not found, falling back to system default")
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
        print("🎙️ [capture] waiting \(String(format: "%.0f", delay * 1000))ms for input to settle")
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
        lastInputBufferTime = 0
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
                    print("🎙️ [capture] setup: engine created (\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms)")

                    let inputNode = localEngine.inputNode
                    print("🎙️ [capture] setup: inputNode accessed (\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms)")

                    let hwFormat = try self.bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)

                    // Use actual hardware format from Core Audio to avoid stale format in inputNode.outputFormat
                    let cachedFormat = inputNode.outputFormat(forBus: 0)
                    let tapFormat: AVAudioFormat
                    if let hwFormat, hwFormat.sampleRate != cachedFormat.sampleRate {
                        tapFormat = hwFormat
                        print(
                            "🎙️ [capture] setup: format override: cached=\(Int(cachedFormat.sampleRate))Hz, " +
                            "hw=\(Int(hwFormat.sampleRate))Hz → using hw format for tap"
                        )
                    } else if let hwFormat {
                        tapFormat = hwFormat
                        print(
                            "🎙️ [capture] setup: format \(Int(hwFormat.sampleRate))Hz \(hwFormat.channelCount)ch (hw matches cached)"
                        )
                    } else {
                        tapFormat = cachedFormat
                        print(
                            "🎙️ [capture] setup: format \(Int(cachedFormat.sampleRate))Hz \(cachedFormat.channelCount)ch (system default)"
                        )
                    }

                    guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
                        print("❌ [capture] setup: FAILED format invalid sampleRate=\(tapFormat.sampleRate)")
                        continuation.resume(throwing: RecordingError.invalidFormat)
                        return
                    }

                    // Crear archivo temporal para guardar el audio
                    let tempDir = FileManager.default.temporaryDirectory
                    let fileName = "recording_\(Date().timeIntervalSince1970).wav"
                    let recordingURL = tempDir.appendingPathComponent(fileName)
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

                    let setupMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    print("🎙️ [capture] setup: total \(setupMs)ms (off-main)")
                    SapoLog.recording.info("Recorder setup completed in \(setupMs, privacy: .public)ms")

                    continuation.resume(returning: (localEngine, recordingURL))
                } catch {
                    self.cleanupSetupArtifacts(engine: engine, recordingURL: pendingRecordingURL, deleteTemporaryFile: true)
                    print("❌ [capture] setup: FAILED \(error)")
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
            print("🎙️ [capture] input already bound -> \(deviceName)")
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
            print("❌ [capture] failed to bind input directly -> \(deviceName) (status: \(setStatus))")
            throw RecordingError.deviceSelectionFailed(setStatus)
        }

        print("🎙️ [capture] bound input directly -> \(deviceName)")
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
            print("⚠️ [capture] could not query device hw format (status: \(status))")
            return nil
        }

        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Procesa el buffer de audio y lo escribe al archivo
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile = audioFile, let outputFormat = converterOutputFormat else { return }
        let inputBufferTime = CFAbsoluteTimeGetCurrent()
        lastInputBufferTime = inputBufferTime
        registerInputBuffer(at: inputBufferTime)
        if !firstInputBufferLogged {
            firstInputBufferLogged = true
            let elapsed = (inputBufferTime - startRecordingTime) * 1000
            let captureDeviceUID = currentCaptureDeviceUID()
            let effectiveDevice = captureDeviceUID == "default" ? "system-default" : captureDeviceUID
            print(
                "🎙️ [capture] first input buffer in \(String(format: "%.0f", elapsed))ms " +
                "(\(buffer.frameLength) frames @ \(String(format: "%.0f", buffer.format.sampleRate))Hz, input: \(effectiveDevice))"
            )
            let elapsedMs = Int(elapsed)
            SapoLog.recording.info(
                "First input buffer received in \(elapsedMs, privacy: .public)ms frames=\(buffer.frameLength, privacy: .public)"
            )
        }
        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }

        // Lazy converter creation from actual buffer format (avoids stale format cache after device switch)
        if converter == nil {
            let inputFmt = buffer.format
            print(
                "🎙️ [capture] creating converter: \(String(format: "%.0f", inputFmt.sampleRate))Hz " +
                "\(inputFmt.commonFormat == .pcmFormatFloat32 ? "Float32" : "Int16") → " +
                "\(String(format: "%.0f", outputFormat.sampleRate))Hz " +
                "\(outputFormat.commonFormat == .pcmFormatInt16 ? "Int16" : "Float32")"
            )
            converter = AVAudioConverter(from: inputFmt, to: outputFormat)
            if converter == nil {
                print("❌ [capture] failed to create converter from \(inputFmt) to \(outputFormat)")
            }
        }
        guard let converter = converter else { return }

        let frameCapacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        var didPublishLevel = false
        var inputConsumed = false

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                inputConsumed = true
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
                print("❌ [capture] audio conversion failed: \(error?.localizedDescription ?? "unknown")")
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

        do {
            try audioFile.write(from: convertedBuffer)
            registerWrittenFrames(convertedBuffer.frameLength)
        } catch {
            print("❌ [capture] failed to write audio buffer: \(error)")
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

        let url = audioSetupQueue.sync { () -> URL? in
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine?.reset()

            _ = flushRemainingConvertedAudio()

            let currentURL = recordingURL
            audioFile = nil
            audioEngine = nil
            converter = nil
            converterOutputFormat = nil
            recordingURL = nil
            return currentURL
        }

        isRecording = false
        isPaused = false

        let diagnostics = makeCaptureDiagnostics(fileURL: url, referenceTime: stopStart)
        lastCaptureDiagnostics = diagnostics
        if logSummary {
            if diagnostics.receivedInput {
                print(
                    "🎙️ [capture] recorded \(diagnostics.inputBufferCount) buffers, " +
                    "\(diagnostics.writtenFrameCount) frames, \(diagnostics.fileSizeBytes) bytes"
                )
            } else {
                print(
                    "⚠️ [capture] stopped without input buffers " +
                    "(\(diagnostics.fileSizeBytes) bytes, input: \(diagnostics.selectedDeviceUID))"
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
        lastInputBufferTime = 0

        return url
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
              let audioFile = audioFile else {
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
                print("❌ [capture] converter flush failed: \(error?.localizedDescription ?? "unknown")")
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

    private func makeCaptureDiagnostics(fileURL: URL?, referenceTime: CFAbsoluteTime) -> RecordingCaptureDiagnostics {
        os_unfair_lock_lock(&captureStateLock)
        let bufferCount = inputBufferCount
        let frameCount = writtenFrameCount
        let firstLatency = firstInputLatencyMs
        let deviceUID = captureDeviceUID
        os_unfair_lock_unlock(&captureStateLock)

        let lastBufferAgeMs = lastInputBufferTime > 0 ? (referenceTime - lastInputBufferTime) * 1000 : nil
        let fileSizeBytes: Int
        if let fileURL,
           let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue {
            fileSizeBytes = size
        } else {
            fileSizeBytes = 0
        }

        return RecordingCaptureDiagnostics(
            selectedDeviceUID: deviceUID,
            inputBufferCount: bufferCount,
            writtenFrameCount: frameCount,
            firstInputLatencyMs: firstLatency,
            lastBufferAgeMs: lastBufferAgeMs,
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
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }

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
}

struct RecordingCaptureDiagnostics {
    let selectedDeviceUID: String
    let inputBufferCount: Int
    let writtenFrameCount: AVAudioFramePosition
    let firstInputLatencyMs: Double?
    let lastBufferAgeMs: Double?
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
                kAudioUnitErr_CannotDoInCurrentContext
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
        Int(kAudioUnitErr_CannotDoInCurrentContext)
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
        || userInfoDescription.contains("IsFormatSampleRateAndChannelCountValid") {
        return RecordingStartFailureClassification(isTransient: true, reason: "outputHWFormat invalid")
    }

    return RecordingStartFailureClassification(
        isTransient: false,
        reason: nsError.domain.isEmpty ? errorDescription : "\(nsError.domain)(\(nsError.code))"
    )
}
