//
//  AudioRecorder.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation
import AVFoundation
import Combine

/// Maneja la grabación de audio usando AVAudioEngine
class AudioRecorder: ObservableObject {
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    
    private var timer: Timer?
    private var startTime: Date?
    
    /// Formato de audio requerido por Whisper: 16kHz, mono, float32
    private var recordingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }
    
    /// Inicia la grabación de audio
    func startRecording() throws {
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
        startTime = Date()
        
        // Timer para actualizar la duración
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            if let startTime = self?.startTime {
                self?.recordingDuration = Date().timeIntervalSince(startTime)
            }
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
            do {
                try audioFile.write(from: convertedBuffer)
            } catch {
                print("❌ Error escribiendo audio: \(error)")
            }
        }
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
        
        let url = recordingURL
        print("🎤 Grabación detenida: \(recordingDuration) segundos")
        
        recordingDuration = 0
        startTime = nil
        
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
