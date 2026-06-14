//
//  AudioLevelMonitor.swift
//  SapoWhisper
//
//

// AVFAudio's converter/tap callbacks predate Sendable annotations.
@preconcurrency import AVFAudio
import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// Metadata for a recorded audio sample
struct SampleMetadata {
    let sampleRate: Double
    let format: String
    let fileSize: Int

    var formattedSize: String {
        if fileSize >= 1_048_576 {
            return String(format: "%.1f MB", Double(fileSize) / 1_048_576)
        }
        return String(format: "%.0f KB", Double(fileSize) / 1024)
    }
}

/// Monitor de nivel de audio en tiempo real para el micrófono
///
/// Concurrency: engine lifecycle is confined to `monitorQueue` (those members
/// are `nonisolated`); Published state stays on the main actor and is only
/// touched through main-queue hops.
class AudioLevelMonitor: ObservableObject, @unchecked Sendable {

    static let shared = AudioLevelMonitor()

    // nonisolated(unsafe): confined to monitorQueue.
    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var isMonitoring = false

    /// Nivel de audio actual (0.0 - 1.0)
    @Published var audioLevel: Float = 0.0

    /// Nivel pico reciente (para efecto visual)
    @Published var peakLevel: Float = 0.0

    /// Si el monitor está activo
    @Published var isActive = false

    /// Gain/boost de audio (1.0 = normal, 2.0 = 2x amplificación)
    @Published var gain: Float = 1.0 {
        didSet { tapGain = gain }
    }

    // nonisolated(unsafe): tap-thread mirror of UI state. tapGain has a benign
    // race (a buffer processed during a toggle uses the previous value).
    private nonisolated(unsafe) var tapGain: Float = 1.0
    // sampleWriteActive is NOT a benign race: it gates writes to sampleFile, so
    // it is guarded by sampleStateLock together with sampleFile (see below).
    private nonisolated(unsafe) var sampleWriteActive = false

    /// Si hubo un error al iniciar el monitoreo
    @Published var hasError = false
    @Published var errorMessage: String?

    // MARK: - Sample Recording

    @Published var isRecordingSample = false
    @Published var sampleRecordingDuration: TimeInterval = 0
    @Published var rawSampleURL: URL?
    @Published var compressedSampleURL: URL?
    @Published var rawSampleMetadata: SampleMetadata?
    @Published var compressedSampleMetadata: SampleMetadata?

    // sampleFile + sampleWriteActive are touched by the nonisolated tap thread
    // (processBuffer) and the main actor (start/stop/clear), so both go through
    // sampleStateLock. The mic-test sample path is low-frequency, so holding the
    // lock across the file write is fine (it serializes with stop/clear nulling
    // the file mid-write). sampleTapFormat is set before the tap starts.
    private nonisolated(unsafe) var sampleFile: AVAudioFile?
    private nonisolated(unsafe) var sampleTapFormat: AVAudioFormat?
    private nonisolated(unsafe) var sampleStateLock = os_unfair_lock()
    private var sampleRecordingTimer: Timer?
    private var sampleStartTime: Date?

    private var peakDecayTimer: Timer?
    private let monitorQueue = DispatchQueue(label: "com.sapowhisper.audioMonitor.control", qos: .userInitiated)
    // nonisolated(unsafe): confined to monitorQueue.
    private nonisolated(unsafe) var selectedDeviceUID: String = "default"
    private nonisolated(unsafe) var restartGeneration: UInt64 = 0
    private nonisolated(unsafe) var monitoringRequested = false
    private nonisolated(unsafe) var resumeAfterRecorder = false

    private init() {
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
        let initialGain = savedGain > 0 ? Float(savedGain) : 1.0
        self.gain = initialGain
        self.tapGain = initialGain
    }

    /// Inicia el monitoreo del micrófono
    func startMonitoring(deviceUID: String = "default") {
        scheduleMonitoringStart(deviceUID: deviceUID, minimumDelay: 0)
    }

    /// Inicia el AVAudioEngine y bindea el dispositivo directamente al AudioUnit
    private nonisolated func startAudioEngineOnQueue(deviceUID: String) {
        let audioEngine = AVAudioEngine()

        selectedDeviceUID = deviceUID

        do {
            let inputNode = audioEngine.inputNode
            let hwFormat = try bindMonitorDevice(to: inputNode)

            // Use hardware format to avoid stale cache after device switch
            let tapFormat = hwFormat ?? inputNode.outputFormat(forBus: 0)

            guard tapFormat.sampleRate > 0 && tapFormat.channelCount > 0 else {
                setError("Formato de audio inválido")
                return
            }

            sampleTapFormat = tapFormat

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            MicrophonePermission.noteAudioInputGranted()
            self.audioEngine = audioEngine
            isMonitoring = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hasError = false
                    self.errorMessage = nil
                    self.isActive = true
                    self.startPeakDecayTimer()
                    SapoLog.audioRoute.info("Audio level monitoring started")
                }
            }
        } catch {
            setError("Error al iniciar: \(error.localizedDescription)")
            cleanupEngineOnQueue()
        }
    }

    /// Binds the selected device directly on the AudioUnit (does NOT change system default)
    private nonisolated func bindMonitorDevice(to inputNode: AVAudioInputNode) throws -> AVAudioFormat? {
        guard selectedDeviceUID != "default" else { return nil }

        let deviceManager = AudioDeviceManager.shared
        guard let deviceID = deviceManager.getDeviceID(for: selectedDeviceUID) else { return nil }
        guard let audioUnit = inputNode.audioUnit else { return nil }

        var targetDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        if status != noErr {
            SapoLog.audioRoute.warning(
                "Monitor bind failed status=\(status, privacy: .public)"
            )
            return nil
        }

        // Query actual hardware format via Core Audio
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let fmtStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard fmtStatus == noErr else { return nil }

        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Detiene el monitoreo
    func stopMonitoring() {
        if isRecordingSample { stopSampleRecording() }
        clearSampleRecording()
        monitorQueue.async { [weak self] in
            self?.stopMonitoringOnQueue(clearIntent: true, logStop: true)
        }
    }

    /// Limpia recursos sin cambiar el estado de monitoreo
    private nonisolated func cleanupEngineOnQueue() {
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine.reset()
        }
        audioEngine = nil
        sampleTapFormat = nil
        isMonitoring = false
    }

    /// Reinicia el monitoreo con un nuevo dispositivo
    func restartMonitoring(deviceUID: String) {
        scheduleMonitoringStart(
            deviceUID: deviceUID,
            minimumDelay: AudioDeviceManager.shared.captureRouteSettleDelay()
        )
    }

    @discardableResult
    func suspendForRecorder() -> Bool {
        let shouldResume = monitorQueue.sync {
            monitoringRequested
        }

        guard shouldResume else { return false }

        if isRecordingSample { stopSampleRecording() }
        clearSampleRecording()

        monitorQueue.async { [weak self] in
            guard let self else { return }
            self.resumeAfterRecorder = self.monitoringRequested
            self.bumpRestartGeneration()
            self.stopMonitoringOnQueue(clearIntent: false, logStop: false)
            SapoLog.audioRoute.info("Monitor suspended for recorder")
        }
        return true
    }

    func resumeAfterRecorderIfNeeded() {
        let resumeContext = monitorQueue.sync { () -> (shouldResume: Bool, deviceUID: String) in
            let shouldResume = resumeAfterRecorder && monitoringRequested
            resumeAfterRecorder = false
            return (shouldResume, selectedDeviceUID)
        }

        guard resumeContext.shouldResume else { return }
        restartMonitoring(deviceUID: resumeContext.deviceUID)
    }

    private func scheduleMonitoringStart(deviceUID: String, minimumDelay: TimeInterval) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            self.monitoringRequested = true
            self.selectedDeviceUID = deviceUID
            self.resumeAfterRecorder = false
            let generation = self.bumpRestartGeneration()
            self.stopMonitoringOnQueue(clearIntent: false, logStop: false)

            let settleDelay = max(0, minimumDelay)
            if settleDelay > 0 {
                SapoLog.audioRoute.info(
                    "Monitor waiting for route settle delayMs=\(Int(settleDelay * 1000), privacy: .public)"
                )
            }

            self.monitorQueue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                guard let self else { return }
                guard self.monitoringRequested, self.restartGeneration == generation else { return }
                self.startAudioEngineOnQueue(deviceUID: deviceUID)
            }
        }
    }

    private nonisolated func stopMonitoringOnQueue(clearIntent: Bool, logStop: Bool) {
        if clearIntent {
            monitoringRequested = false
            resumeAfterRecorder = false
            bumpRestartGeneration()
        }

        let wasMonitoring = isMonitoring || audioEngine != nil
        cleanupEngineOnQueue()

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.peakDecayTimer?.invalidate()
                self.peakDecayTimer = nil
                self.isActive = false
                self.audioLevel = 0
                self.peakLevel = 0
                if logStop && wasMonitoring {
                    SapoLog.audioRoute.info("Audio level monitoring stopped")
                }
            }
        }
    }

    @discardableResult
    private nonisolated func bumpRestartGeneration() -> UInt64 {
        restartGeneration &+= 1
        return restartGeneration
    }

    private func startPeakDecayTimer() {
        peakDecayTimer?.invalidate()
        peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so the timer always fires on main.
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.peakLevel > self.audioLevel {
                    self.peakLevel = max(self.audioLevel, self.peakLevel - 0.02)
                }
            }
        }
    }

    // MARK: - Sample Recording Methods

    /// Starts recording a sample using the already-running engine tap
    func startSampleRecording() {
        guard isMonitoring, !isRecordingSample else { return }

        clearSampleRecording()

        let monitorSnapshot = monitorQueue.sync { () -> (engine: AVAudioEngine?, tapFormat: AVAudioFormat?, isRunning: Bool) in
            (audioEngine, sampleTapFormat, isMonitoring)
        }
        guard let audioEngine = monitorSnapshot.engine, monitorSnapshot.isRunning else { return }

        let tapFormat = monitorSnapshot.tapFormat ?? audioEngine.inputNode.outputFormat(forBus: 0)
        let rawURL = TemporaryAudioStorage.makeWAVURL(prefix: "mic_test_raw")

        do {
            let file = try AVAudioFile(forWriting: rawURL, settings: tapFormat.settings)
            os_unfair_lock_lock(&sampleStateLock)
            sampleFile = file
            sampleWriteActive = true
            os_unfair_lock_unlock(&sampleStateLock)
            rawSampleURL = rawURL
            isRecordingSample = true
            sampleStartTime = Date()
            sampleRecordingDuration = 0

            sampleRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                // Scheduled on the main run loop, so the timer always fires on main.
                MainActor.assumeIsolated {
                    guard let self, let start = self.sampleStartTime else { return }
                    self.sampleRecordingDuration = Date().timeIntervalSince(start)
                }
            }

            SapoLog.audioRoute.info("Mic sample recording started")
        } catch {
            SapoLog.audioRoute.error(
                "Mic sample file create failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Stops recording and converts raw → 16kHz int16
    func stopSampleRecording() {
        guard isRecordingSample else { return }

        os_unfair_lock_lock(&sampleStateLock)
        sampleWriteActive = false
        sampleFile = nil
        os_unfair_lock_unlock(&sampleStateLock)
        sampleRecordingTimer?.invalidate()
        sampleRecordingTimer = nil
        isRecordingSample = false

        guard let rawURL = rawSampleURL else { return }

        // Build raw metadata
        rawSampleMetadata = buildMetadata(for: rawURL)

        // Convert to compressed (16kHz int16 mono)
        let compressedURL = TemporaryAudioStorage.makeWAVURL(prefix: "mic_test_compressed")

        if convertToCompressed(from: rawURL, to: compressedURL) {
            self.compressedSampleURL = compressedURL
            self.compressedSampleMetadata = buildMetadata(for: compressedURL)
            SapoLog.audioRoute.info("Mic sample stopped raw+compressed=true")
        } else {
            SapoLog.audioRoute.warning("Mic sample compression failed, raw-only available")
        }
    }

    /// Clears recorded sample files
    func clearSampleRecording() {
        os_unfair_lock_lock(&sampleStateLock)
        sampleWriteActive = false
        sampleFile = nil
        os_unfair_lock_unlock(&sampleStateLock)
        sampleRecordingTimer?.invalidate()
        sampleRecordingTimer = nil
        isRecordingSample = false
        sampleRecordingDuration = 0
        sampleStartTime = nil

        if let url = rawSampleURL { try? FileManager.default.removeItem(at: url) }
        if let url = compressedSampleURL { try? FileManager.default.removeItem(at: url) }
        rawSampleURL = nil
        compressedSampleURL = nil
        rawSampleMetadata = nil
        compressedSampleMetadata = nil
    }

    private func buildMetadata(for url: URL) -> SampleMetadata? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        let formatName: String
        switch format.commonFormat {
        case .pcmFormatFloat32: formatName = "Float32"
        case .pcmFormatInt16: formatName = "Int16"
        case .pcmFormatFloat64: formatName = "Float64"
        case .pcmFormatInt32: formatName = "Int32"
        default: formatName = "PCM"
        }

        return SampleMetadata(
            sampleRate: format.sampleRate,
            format: formatName,
            fileSize: fileSize
        )
    }

    private func convertToCompressed(from rawURL: URL, to outputURL: URL) -> Bool {
        guard let inputFile = try? AVAudioFile(forReading: rawURL) else { return false }

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: outputFormat) else { return false }

        guard
            let outputFile = try? AVAudioFile(
                forWriting: outputURL,
                settings: outputFormat.settings,
                commonFormat: outputFormat.commonFormat,
                interleaved: outputFormat.isInterleaved
            )
        else { return false }

        // Read entire input at once — sample recordings are short so memory is fine
        let totalFrames = AVAudioFrameCount(inputFile.length)
        guard totalFrames > 0,
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: totalFrames)
        else { return false }

        do { try inputFile.read(into: inputBuffer) } catch { return false }

        let outputFrameCount = AVAudioFrameCount(
            ceil(Double(totalFrames) * outputFormat.sampleRate / inputFile.processingFormat.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return false }

        var error: NSError?
        // The input block runs synchronously inside convert(); the lock only
        // satisfies the Sendable contract of the SDK callback.
        let inputConsumed = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
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

        guard status == .haveData, outputBuffer.frameLength > 0 else {
            SapoLog.audioRoute.error(
                "Mic sample conversion failed error=\(error?.localizedDescription ?? "no output", privacy: .public)"
            )
            return false
        }

        do { try outputFile.write(from: outputBuffer) } catch { return false }
        return true
    }

    // MARK: - Audio Level Processing

    /// Applies gain to a copy of the buffer (leaves original untouched)
    private nonisolated func bufferWithGain(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let srcData = buffer.floatChannelData else { return nil }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        guard let dstData = copy.floatChannelData else { return nil }

        let count = Int(buffer.frameLength)
        for i in 0..<count {
            dstData[0][i] = max(-1.0, min(1.0, srcData[0][i] * tapGain))
        }
        return copy
    }

    /// Writes the tap buffer to the active mic-test sample file under
    /// `sampleStateLock`, so a concurrent stop/clear on the main actor cannot
    /// null the file mid-write. Mic-test path only, so holding the lock across the
    /// write is acceptable; when no sample is recording the lock is uncontended
    /// and released immediately (correctness over realtime purity for Settings).
    private nonisolated func writeSampleBuffer(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&sampleStateLock)
        defer { os_unfair_lock_unlock(&sampleStateLock) }
        guard sampleWriteActive, let sampleFile else { return }
        do {
            if tapGain != 1.0, let gained = bufferWithGain(buffer) {
                try sampleFile.write(from: gained)
            } else {
                try sampleFile.write(from: buffer)
            }
        } catch {
            SapoLog.audioRoute.error(
                "Mic sample write failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Procesa el buffer de audio y extrae el nivel
    private nonisolated func processBuffer(_ buffer: AVAudioPCMBuffer) {
        // Write to the sample file if mic-test recording is active (guarded).
        writeSampleBuffer(buffer)

        guard let channelData = buffer.floatChannelData else { return }
        guard buffer.frameLength > 0 else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map {
            channelDataValue[$0]
        }

        guard !channelDataValueArray.isEmpty else { return }

        // Calcular RMS (Root Mean Square) para un nivel más suave
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(channelDataValueArray.count))

        // Aplicar gain
        let amplifiedRms = rms * tapGain

        // Convertir a escala logarítmica para mejor visualización
        let avgPower = 20 * log10(max(amplifiedRms, 0.0001))  // Evitar log(0)

        // Normalizar a 0-1 (asumiendo rango de -60dB a 0dB)
        let minDb: Float = -60
        let maxDb: Float = 0
        let normalizedLevel = max(0, min(1, (avgPower - minDb) / (maxDb - minDb)))

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }

                // Suavizar el nivel con interpolación
                self.audioLevel = self.audioLevel * 0.7 + normalizedLevel * 0.3

                // Actualizar pico si es mayor
                if normalizedLevel > self.peakLevel {
                    self.peakLevel = normalizedLevel
                }
            }
        }
    }

    /// Establece un error
    private nonisolated func setError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                SapoLog.audioRoute.error(
                    "AudioLevelMonitor error message=\(message, privacy: .public)"
                )
                self?.hasError = true
                self?.errorMessage = message
                self?.isActive = false
                self?.peakDecayTimer?.invalidate()
                self?.peakDecayTimer = nil
                self?.audioLevel = 0
                self?.peakLevel = 0
            }
        }
    }

}
