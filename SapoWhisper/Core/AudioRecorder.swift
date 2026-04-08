//
//  AudioRecorder.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation
import AVFoundation
import CoreAudio
import Combine

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
    private let converterLock = NSLock()
    private let tapBufferSize: AVAudioFrameCount = 1024
    private var startRecordingTime: CFAbsoluteTime = 0
    private var firstInputBufferLogged = false
    private var lastInputBufferTime: CFAbsoluteTime = 0

    /// UID del dispositivo de audio seleccionado
    var selectedDeviceUID: String = "default"

    /// Standard recording format shared by local and cloud engines.
    /// Int16 cuts file size in half vs float32 and removes an extra conversion for cloud uploads.
    private var recordingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    /// Configura el dispositivo de entrada de audio
    private func configureInputDevice() {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard selectedDeviceUID != "default" else { return }

        guard let deviceID = AudioDeviceManager.shared.getDeviceID(for: selectedDeviceUID) else {
            print("⚠️ Dispositivo no encontrado, usando default")
            return
        }

        if let currentDefaultDevice = AudioDeviceManager.shared.getSystemDefaultInputDevice(),
           currentDefaultDevice == deviceID {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [audio device] already default in \(String(format: "%.0f", elapsed))ms: \(selectedDeviceUID)")
            return
        }

        var deviceIDValue = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDValue
        )

        if status == noErr {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("⏱️ [audio device] configured in \(String(format: "%.0f", elapsed))ms: \(selectedDeviceUID)")
        } else {
            print("❌ Error configurando dispositivo: \(status)")
        }
    }

    /// Inicia la grabación de audio
    func startRecording() throws {
        // Configurar dispositivo de entrada si no es default
        configureInputDevice()

        // Crear nuevo audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw RecordingError.engineCreationFailed
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Crear archivo temporal para guardar el audio
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
        recordingURL = tempDir.appendingPathComponent(fileName)

        guard let recordingURL = recordingURL else {
            throw RecordingError.fileCreationFailed
        }

        // Configurar el formato de salida (16kHz mono para Whisper)
        let outputFormat = recordingFormat

        // AVAudioFile(forWriting:settings:) always uses float32 as processing format.
        // We need the client format to match the converted int16 buffers we write.
        audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        // Crear converter para convertir del formato de entrada al formato de Whisper
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.converterCreationFailed
        }
        self.converter = converter
        self.converterOutputFormat = outputFormat

        // Instalar tap en el input node
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        // Preparar e iniciar el engine
        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        isPaused = false
        accumulatedDuration = 0
        startTime = Date()
        startRecordingTime = CFAbsoluteTimeGetCurrent()
        let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
        activeGain = Float(savedGain > 0 ? savedGain : 1.0)
        lastAudioLevelPublishTime = 0
        firstInputBufferLogged = false
        lastInputBufferTime = 0

        // Timer para actualizar la duración
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }

        print("🎤 Grabación iniciada: \(recordingURL.path)")
    }

    /// Procesa el buffer de audio y lo escribe al archivo
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        guard let audioFile = audioFile else { return }
        let inputBufferTime = CFAbsoluteTimeGetCurrent()
        lastInputBufferTime = inputBufferTime
        if !firstInputBufferLogged {
            firstInputBufferLogged = true
            let elapsed = (inputBufferTime - startRecordingTime) * 1000
            print(
                "⏱️ [recorder tap] first input buffer in \(String(format: "%.0f", elapsed))ms " +
                "(\(buffer.frameLength) frames @ \(String(format: "%.0f", buffer.format.sampleRate))Hz)"
            )
        }
        converterLock.lock()
        defer { converterLock.unlock() }

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
                print("❌ Error convirtiendo audio: \(error?.localizedDescription ?? "unknown")")
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
        } catch {
            print("❌ Error escribiendo audio: \(error)")
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

        print("⏸ Grabación pausada: \(accumulatedDuration) segundos acumulados")
    }

    /// Reanuda la grabación después de una pausa
    func resumeRecording() throws {
        guard isRecording, isPaused else { return }

        try audioEngine?.start()
        isPaused = false
        startTime = Date()
        lastAudioLevelPublishTime = 0

        // Reiniciar timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }

        print("▶️ Grabación reanudada")
    }

    /// Detiene la grabación y retorna la URL del archivo
    func stopRecording() -> URL? {
        let stopStart = CFAbsoluteTimeGetCurrent()
        timer?.invalidate()
        timer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        let removeTapElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
        audioEngine?.stop()
        let stopEngineElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000
        audioEngine?.reset()
        let resetElapsed = (CFAbsoluteTimeGetCurrent() - stopStart) * 1000

        let flushStats = flushRemainingConvertedAudio()

        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil
        isRecording = false
        isPaused = false

        let url = recordingURL
        print("🎤 Grabación detenida: \(recordingDuration) segundos")
        let timeSinceLastBuffer = lastInputBufferTime > 0 ? (stopStart - lastInputBufferTime) * 1000 : -1
        print(
            "⏱️ [stop audio] removeTap \(String(format: "%.0f", removeTapElapsed))ms | " +
            "stop \(String(format: "%.0f", stopEngineElapsed - removeTapElapsed))ms | " +
            "reset \(String(format: "%.0f", resetElapsed - stopEngineElapsed))ms | " +
            "flush \(String(format: "%.0f", flushStats.elapsedMs))ms " +
            "(\(flushStats.chunks) chunks, \(flushStats.frames) frames) | " +
            "last buffer \(timeSinceLastBuffer >= 0 ? String(format: "%.0f", timeSinceLastBuffer) : "n/a")ms before stop"
        )

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

    /// Flushes any delayed samples still buffered inside AVAudioConverter.
    private func flushRemainingConvertedAudio() -> (chunks: Int, frames: AVAudioFrameCount, elapsedMs: Double) {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let converter = converter,
              let outputFormat = converterOutputFormat,
              let audioFile = audioFile else {
            return (0, 0, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }

        converterLock.lock()
        defer { converterLock.unlock() }

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
                print("❌ Error flushing audio converter: \(error?.localizedDescription ?? "unknown")")
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
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case engineCreationFailed
    case fileCreationFailed
    case converterCreationFailed
    case permissionDenied

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
        }
    }
}
