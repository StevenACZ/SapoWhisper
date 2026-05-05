//
//  WhisperTranscriber.swift
//  SapoWhisper
//
//
//  Motor de transcripción usando Speech Recognition de Apple (Online).
//  Este es el motor secundario que requiere internet pero no necesita configuración.
//

import AppKit
import Combine
import Foundation
import Speech

/// Maneja la transcripción de audio usando Speech Recognition de Apple
@MainActor
class WhisperTranscriber: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?

    private var speechRecognizer: SFSpeechRecognizer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupSpeechRecognition()
        observeAppActivation()
    }

    private func setupSpeechRecognition() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
        refreshAuthorizationStatus()
    }

    private func observeAppActivation() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAuthorizationStatus()
            }
            .store(in: &cancellables)
    }

    func refreshAuthorizationStatus() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            isModelLoaded = true
            errorMessage = nil
        case .denied, .restricted:
            isModelLoaded = false
            errorMessage = "permissions.speech.denied_error".localized
        case .notDetermined:
            isModelLoaded = false
            errorMessage = nil
        @unknown default:
            isModelLoaded = false
        }
    }

    /// Transcribe un archivo de audio usando Speech Recognition de Apple
    func transcribe(audioURL: URL, language: String = "es") async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            refreshAuthorizationStatus()
            throw TranscriberError.permissionDenied
        }

        isTranscribing = true
        progress = 0.1
        errorMessage = nil

        defer {
            isTranscribing = false
            progress = 1.0
        }

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

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        progress = 0.5

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
    case permissionDenied
    case modelNotDownloaded
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "permissions.speech.denied_error".localized
        case .modelNotDownloaded:
            return "El modelo no está descargado"
        case .modelNotLoaded:
            return "El modelo no está cargado"
        case .transcriptionFailed(let message):
            return "Transcripción fallida: \(message)"
        }
    }
}
