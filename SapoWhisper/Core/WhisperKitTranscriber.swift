//
//  WhisperKitTranscriber.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//
//  Transcriptor local usando WhisperKit (optimizado para Apple Silicon)
//

import Foundation
import Combine

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Maneja la transcripcion de audio usando WhisperKit (100% local)
@MainActor
class WhisperKitTranscriber: ObservableObject {

    // MARK: - Published Properties

    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var loadingProgress: Double = 0
    @Published var loadingMessage: String = ""
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    @Published var currentModelName: String?

    // MARK: - Private Properties

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    private var currentModel: WhisperKitModel?

    // MARK: - Initialization

    init() {
        print("WhisperKitTranscriber inicializado")
    }

    // MARK: - Model Management

    /// Carga un modelo de WhisperKit
    /// WhisperKit descarga automaticamente el modelo si no existe localmente
    func loadModel(_ model: WhisperKitModel, language: String = "es") async throws {
        #if canImport(WhisperKit)
        guard !isLoading else {
            print("Ya hay un modelo cargandose")
            return
        }

        isLoading = true
        isModelLoaded = false
        loadingProgress = 0
        loadingMessage = "Preparando \(model.displayName)..."
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            print("Cargando modelo WhisperKit: \(model.rawValue)")
            loadingMessage = "Descargando modelo (si es necesario)..."
            loadingProgress = 0.2

            // Configuracion de WhisperKit
            let config = WhisperKitConfig(
                model: model.rawValue,
                verbose: true,
                prewarm: true
            )

            loadingMessage = "Inicializando WhisperKit..."
            loadingProgress = 0.5

            // Inicializar WhisperKit (descarga automaticamente si no existe)
            whisperKit = try await WhisperKit(config)

            loadingMessage = "Modelo listo"
            loadingProgress = 1.0

            currentModel = model
            currentModelName = model.displayName
            isModelLoaded = true

            print("Modelo WhisperKit cargado exitosamente: \(model.displayName)")

        } catch {
            errorMessage = "Error cargando modelo: \(error.localizedDescription)"
            print("Error cargando WhisperKit: \(error)")
            throw WhisperKitError.modelLoadFailed(error.localizedDescription)
        }
        #else
        throw WhisperKitError.notAvailable
        #endif
    }

    /// Descarga el modelo actual de memoria
    func unloadModel() {
        #if canImport(WhisperKit)
        whisperKit = nil
        #endif
        isModelLoaded = false
        currentModel = nil
        currentModelName = nil
        print("Modelo WhisperKit descargado de memoria")
    }

    // MARK: - Transcription

    /// Transcribe un archivo de audio usando WhisperKit
    func transcribe(audioURL: URL, language: String = "es") async throws -> String {
        #if canImport(WhisperKit)
        guard isModelLoaded, let whisperKit = whisperKit else {
            throw WhisperKitError.modelNotLoaded
        }

        isTranscribing = true
        progress = 0
        errorMessage = nil

        defer {
            isTranscribing = false
            progress = 1.0
        }

        do {
            print("Iniciando transcripcion WhisperKit: \(audioURL.lastPathComponent)")
            progress = 0.1

            // Configurar opciones de decodificacion
            var options = DecodingOptions()
            options.language = language == "auto" ? nil : language

            progress = 0.3

            // Realizar transcripcion
            let results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )

            progress = 0.9

            // Obtener texto de los resultados
            let transcription = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            lastTranscription = transcription
            progress = 1.0

            print("Transcripcion WhisperKit completada: \(transcription.prefix(100))...")
            return transcription

        } catch {
            errorMessage = "Error en transcripcion: \(error.localizedDescription)"
            print("Error en transcripcion WhisperKit: \(error)")
            throw WhisperKitError.transcriptionFailed(error.localizedDescription)
        }
        #else
        throw WhisperKitError.notAvailable
        #endif
    }

    // MARK: - Helpers

    /// Verifica si WhisperKit esta disponible en el sistema
    var isAvailable: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    /// Nombre del modelo cargado o nil si no hay modelo
    var loadedModelName: String? {
        currentModelName
    }
}

// MARK: - Errors

enum WhisperKitError: LocalizedError {
    case notAvailable
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "WhisperKit no esta disponible. Agrega el package en Xcode."
        case .modelNotLoaded:
            return "No hay un modelo cargado"
        case .modelLoadFailed(let message):
            return "Error cargando modelo: \(message)"
        case .transcriptionFailed(let message):
            return "Error en transcripcion: \(message)"
        }
    }
}
