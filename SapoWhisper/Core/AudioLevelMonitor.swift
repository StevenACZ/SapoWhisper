//
//  AudioLevelMonitor.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

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
class AudioLevelMonitor: ObservableObject {

    static let shared = AudioLevelMonitor()

    private var audioEngine: AVAudioEngine?
    private var isMonitoring = false

    /// Nivel de audio actual (0.0 - 1.0)
    @Published var audioLevel: Float = 0.0

    /// Nivel pico reciente (para efecto visual)
    @Published var peakLevel: Float = 0.0

    /// Si el monitor está activo
    @Published var isActive = false

    /// Gain/boost de audio (1.0 = normal, 2.0 = 2x amplificación)
    @Published var gain: Float = 1.0

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

    private var sampleFile: AVAudioFile?
    private var sampleTapFormat: AVAudioFormat?
    private var sampleRecordingTimer: Timer?
    private var sampleStartTime: Date?

    private var peakDecayTimer: Timer?
    private var selectedDeviceUID: String = "default"

    private init() {
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
        self.gain = savedGain > 0 ? Float(savedGain) : 1.0
    }
    
    /// Inicia el monitoreo del micrófono
    func startMonitoring(deviceUID: String = "default") {
        guard !isMonitoring else { return }

        hasError = false
        errorMessage = nil
        selectedDeviceUID = deviceUID

        startAudioEngine()
    }

    /// Inicia el AVAudioEngine y bindea el dispositivo directamente al AudioUnit
    private func startAudioEngine() {
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            setError("No se pudo crear el motor de audio")
            return
        }

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
            isMonitoring = true
            isActive = true

            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.peakLevel > self.audioLevel {
                    self.peakLevel = max(self.audioLevel, self.peakLevel - 0.02)
                }
            }

            print("🎤 Monitoreo de nivel iniciado")
        } catch {
            setError("Error al iniciar: \(error.localizedDescription)")
            cleanup()
        }
    }

    /// Binds the selected device directly on the AudioUnit (does NOT change system default)
    private func bindMonitorDevice(to inputNode: AVAudioInputNode) throws -> AVAudioFormat? {
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
            print("⚠️ [audio monitor] failed to bind device (status: \(status))")
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
        guard isMonitoring else { return }

        if isRecordingSample { stopSampleRecording() }
        clearSampleRecording()
        cleanup()

        isMonitoring = false
        isActive = false
        audioLevel = 0
        peakLevel = 0
        sampleTapFormat = nil

        print("🎤 Monitoreo de nivel detenido")
    }
    
    /// Limpia recursos sin cambiar el estado de monitoreo
    private func cleanup() {
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
        
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        audioEngine = nil
    }
    
    /// Reinicia el monitoreo con un nuevo dispositivo
    func restartMonitoring(deviceUID: String) {
        stopMonitoring()
        
        // Delay para que el sistema libere el dispositivo
        let delay: Double = 0.3
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startMonitoring(deviceUID: deviceUID)
        }
    }
    
    // MARK: - Sample Recording Methods

    /// Starts recording a sample using the already-running engine tap
    func startSampleRecording() {
        guard isMonitoring, !isRecordingSample else { return }

        clearSampleRecording()

        guard let audioEngine, audioEngine.isRunning else { return }

        let tapFormat = sampleTapFormat ?? audioEngine.inputNode.outputFormat(forBus: 0)
        let tempDir = FileManager.default.temporaryDirectory
        let rawURL = tempDir.appendingPathComponent("mic_test_raw_\(Date().timeIntervalSince1970).wav")

        do {
            sampleFile = try AVAudioFile(forWriting: rawURL, settings: tapFormat.settings)
            rawSampleURL = rawURL
            isRecordingSample = true
            sampleStartTime = Date()
            sampleRecordingDuration = 0

            sampleRecordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let start = self.sampleStartTime else { return }
                self.sampleRecordingDuration = Date().timeIntervalSince(start)
            }

            print("🎤 [sample] recording started")
        } catch {
            print("❌ [sample] failed to create file: \(error)")
        }
    }

    /// Stops recording and converts raw → 16kHz int16
    func stopSampleRecording() {
        guard isRecordingSample else { return }

        sampleRecordingTimer?.invalidate()
        sampleRecordingTimer = nil
        isRecordingSample = false
        sampleFile = nil

        guard let rawURL = rawSampleURL else { return }

        // Build raw metadata
        rawSampleMetadata = buildMetadata(for: rawURL)

        // Convert to compressed (16kHz int16 mono)
        let compressedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic_test_compressed_\(Date().timeIntervalSince1970).wav")

        if convertToCompressed(from: rawURL, to: compressedURL) {
            self.compressedSampleURL = compressedURL
            self.compressedSampleMetadata = buildMetadata(for: compressedURL)
            print("🎤 [sample] recording stopped, raw + compressed ready")
        } else {
            print("⚠️ [sample] compression failed, raw-only available")
        }
    }

    /// Clears recorded sample files
    func clearSampleRecording() {
        sampleFile = nil
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

        guard let outputFile = try? AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        ) else { return false }

        // Read entire input at once — sample recordings are short so memory is fine
        let totalFrames = AVAudioFrameCount(inputFile.length)
        guard totalFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: totalFrames)
        else { return false }

        do { try inputFile.read(into: inputBuffer) } catch { return false }

        let outputFrameCount = AVAudioFrameCount(ceil(Double(totalFrames) * outputFormat.sampleRate / inputFile.processingFormat.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else { return false }

        var error: NSError?
        var inputConsumed = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status == .haveData, outputBuffer.frameLength > 0 else {
            print("❌ [sample] conversion failed: \(error?.localizedDescription ?? "no output")")
            return false
        }

        do { try outputFile.write(from: outputBuffer) } catch { return false }
        return true
    }

    // MARK: - Audio Level Processing

    /// Procesa el buffer de audio y extrae el nivel
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        // Write to sample file if recording
        if isRecordingSample, let sampleFile {
            do { try sampleFile.write(from: buffer) } catch {
                print("❌ [sample] write failed: \(error)")
            }
        }

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
        let amplifiedRms = rms * gain
        
        // Convertir a escala logarítmica para mejor visualización
        let avgPower = 20 * log10(max(amplifiedRms, 0.0001)) // Evitar log(0)
        
        // Normalizar a 0-1 (asumiendo rango de -60dB a 0dB)
        let minDb: Float = -60
        let maxDb: Float = 0
        let normalizedLevel = max(0, min(1, (avgPower - minDb) / (maxDb - minDb)))
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Suavizar el nivel con interpolación
            self.audioLevel = self.audioLevel * 0.7 + normalizedLevel * 0.3
            
            // Actualizar pico si es mayor
            if normalizedLevel > self.peakLevel {
                self.peakLevel = normalizedLevel
            }
        }
    }
    
    /// Establece un error
    private func setError(_ message: String) {
        print("❌ AudioLevelMonitor: \(message)")
        hasError = true
        errorMessage = message
        isActive = false
    }
    
    deinit {
        stopMonitoring()
    }
}
