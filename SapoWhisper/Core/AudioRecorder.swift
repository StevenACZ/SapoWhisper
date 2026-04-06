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

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0

    private var timer: Timer?
    private var startTime: Date?
    private var accumulatedDuration: TimeInterval = 0

    /// UID del dispositivo de audio seleccionado
    var selectedDeviceUID: String = "default"

    /// Formato de audio requerido por Whisper: 16kHz, mono, float32
    private var recordingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    /// Configura el dispositivo de entrada de audio
    private func configureInputDevice() {
        guard selectedDeviceUID != "default" else { return }

        guard let deviceID = AudioDeviceManager.shared.getDeviceID(for: selectedDeviceUID) else {
            print("⚠️ Dispositivo no encontrado, usando default")
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
            print("✅ Dispositivo de entrada configurado: \(selectedDeviceUID)")
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

        // Crear el archivo de audio
        audioFile = try AVAudioFile(forWriting: recordingURL, settings: outputFormat.settings)

        // Crear converter para convertir del formato de entrada al formato de Whisper
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.converterCreationFailed
        }

        // Instalar tap en el input node
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
        }

        // Preparar e iniciar el engine
        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        isPaused = false
        accumulatedDuration = 0
        startTime = Date()

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

        let frameCount = AVAudioFrameCount(outputFormat.sampleRate * Double(buffer.frameLength) / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .haveData {
            // Apply saved gain to recording
            let savedGain = UserDefaults.standard.double(forKey: Constants.StorageKeys.audioGain)
            let effectiveGain = Float(savedGain > 0 ? savedGain : 1.0)
            if effectiveGain != 1.0, let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                for i in 0..<frameCount {
                    channelData[0][i] *= effectiveGain
                }
            }

            do {
                try audioFile.write(from: convertedBuffer)
            } catch {
                print("❌ Error escribiendo audio: \(error)")
            }
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

        print("⏸ Grabación pausada: \(accumulatedDuration) segundos acumulados")
    }

    /// Reanuda la grabación después de una pausa
    func resumeRecording() throws {
        guard isRecording, isPaused else { return }

        try audioEngine?.start()
        isPaused = false
        startTime = Date()

        // Reiniciar timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(startTime)
        }

        print("▶️ Grabación reanudada")
    }

    /// Detiene la grabación y retorna la URL del archivo
    func stopRecording() -> URL? {
        timer?.invalidate()
        timer = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        audioFile = nil
        isRecording = false
        isPaused = false

        let url = recordingURL
        print("🎤 Grabación detenida: \(recordingDuration) segundos")

        recordingDuration = 0
        startTime = nil
        accumulatedDuration = 0

        return url
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
