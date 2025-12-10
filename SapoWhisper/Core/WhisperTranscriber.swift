//
//  WhisperTranscriber.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//  
//  Motor de transcripción usando Speech Recognition de Apple (Online).
//  Este es el motor secundario que requiere internet pero no necesita configuración.
//

import Foundation
import AVFoundation
import Speech
import Combine

/// Maneja la transcripción de audio usando Speech Recognition de Apple
@MainActor
class WhisperTranscriber: ObservableObject {
    
    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    
    private var speechRecognizer: SFSpeechRecognizer?
    
    init() {
        setupSpeechRecognition()
    }
    
    private func setupSpeechRecognition() {
        // Configurar Speech Recognition
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        
        // Solicitar permisos de Speech Recognition
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    print("✅ Speech Recognition autorizado")
                    self?.isModelLoaded = true
                case .denied, .restricted:
                    print("❌ Speech Recognition denegado")
                    self?.errorMessage = "Permisos de reconocimiento de voz denegados"
                case .notDetermined:
                    print("⏳ Speech Recognition no determinado")
                @unknown default:
                    break
                }
            }
        }
    }
    
    /// Transcribe un archivo de audio usando Speech Recognition de Apple
    func transcribe(audioURL: URL, language: String = "es") async throws -> String {
        guard isModelLoaded else {
            throw TranscriberError.modelNotLoaded
        }

        isTranscribing = true
        progress = 0.1
        errorMessage = nil

        defer {
            isTranscribing = false
            progress = 1.0
        }

        // Configurar el reconocedor con el idioma correcto
        let recognizer: SFSpeechRecognizer?

        switch language {
        case "es":
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        case "en":
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        case "auto":
            // Usar el idioma del sistema para auto-detección
            recognizer = SFSpeechRecognizer()
        default:
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        }

        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw TranscriberError.transcriptionFailed("Speech Recognition no disponible para \(language)")
        }
        
        progress = 0.3
        
        // Crear la solicitud de reconocimiento
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        
        progress = 0.5
        
        // Realizar la transcripción
        let transcription = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                if let result = result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    continuation.resume(returning: text)
                }
            }
        }
        
        progress = 1.0
        lastTranscription = transcription
        print("✅ Transcripción completada: \(transcription.prefix(100))...")
        
        return transcription
    }
    
    /// Verifica si hay un modelo disponible
    var hasAvailableModel: Bool {
        speechRecognizer?.isAvailable == true
    }
    
    /// Obtiene el nombre del motor de transcripción
    var loadedModelName: String? {
        "Apple Speech Recognition"
    }
}

// MARK: - Errors

enum TranscriberError: LocalizedError {
    case modelNotDownloaded
    case modelNotLoaded
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "El modelo no está descargado"
        case .modelNotLoaded:
            return "El modelo no está cargado"
        case .transcriptionFailed(let message):
            return "Transcripción fallida: \(message)"
        }
    }
}
