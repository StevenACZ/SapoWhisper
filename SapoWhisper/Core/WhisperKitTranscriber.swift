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

    // MARK: - Loading State Enum
    
    enum LoadingState: String {
        case idle = "Listo"
        case downloading = "Descargando modelo..."
        case prewarming = "Preparando modelo..."
        case loading = "Cargando modelo..."
        case ready = "Modelo listo ✓"
        case error = "Error"
    }

    // MARK: - Published Properties

    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isTranscribing = false
    @Published var progress: Double = 0
    @Published var loadingProgress: Double = 0
    @Published var loadingMessage: String = ""
    @Published var loadingState: LoadingState = .idle
    @Published var lastTranscription: String = ""
    @Published var errorMessage: String?
    @Published var currentModelName: String?

    // MARK: - Private Properties

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    private var currentModel: WhisperKitModel?
    
    /// Key para guardar modelos descargados en UserDefaults
    private let downloadedModelsKey = "whisperkit_downloaded_models"

    // MARK: - Initialization

    init() {
        print("WhisperKitTranscriber inicializado")
        loadDownloadedModelsFromStorage()
    }
    
    /// Carga los modelos descargados desde UserDefaults
    private func loadDownloadedModelsFromStorage() {
        if let savedModels = UserDefaults.standard.stringArray(forKey: downloadedModelsKey) {
            for modelName in savedModels {
                if let model = WhisperKitModel(rawValue: modelName) {
                    downloadedModels.insert(model)
                }
            }
            print("📦 Modelos descargados cargados: \(downloadedModels.map { $0.displayName })")
        }
    }
    
    /// Guarda los modelos descargados en UserDefaults
    private func saveDownloadedModelsToStorage() {
        let modelNames = downloadedModels.map { $0.rawValue }
        UserDefaults.standard.set(modelNames, forKey: downloadedModelsKey)
    }

    // MARK: - Model Management

    /// Carga un modelo de WhisperKit
    /// WhisperKit descarga automaticamente el modelo si no existe localmente
    /// Incluye reintentos automaticos para manejar errores de red
    func loadModel(_ model: WhisperKitModel, language: String = "es") async throws {
        #if canImport(WhisperKit)
        guard !isLoading else {
            print("Ya hay un modelo cargandose")
            return
        }

        isLoading = true
        isModelLoaded = false
        loadingProgress = 0
        errorMessage = nil
        
        // Verificar si el modelo ya esta descargado
        let alreadyDownloaded = isModelDownloaded(model)

        defer {
            isLoading = false
        }

        let maxRetries = 3
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                print("Cargando modelo WhisperKit: \(model.rawValue) (intento \(attempt)/\(maxRetries))")
                
                if attempt > 1 {
                    loadingState = .downloading
                    loadingMessage = "Reintentando descarga (\(attempt)/\(maxRetries))..."
                    // Esperar antes de reintentar (delay incremental)
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) // 2s, 4s, 6s
                } else if alreadyDownloaded {
                    // Modelo ya descargado, solo prewarming
                    loadingState = .prewarming
                    loadingMessage = "Preparando \(model.displayName)..."
                } else {
                    // Modelo nuevo, necesita descarga
                    loadingState = .downloading
                    loadingMessage = "Descargando \(model.displayName)..."
                }
                loadingProgress = 0.2

                // Configuracion de WhisperKit
                let config = WhisperKitConfig(
                    model: model.rawValue,
                    verbose: true,
                    prewarm: true
                )

                // Actualizar estado a prewarming cuando empieza la inicializacion
                if !alreadyDownloaded {
                    loadingProgress = 0.5
                    loadingState = .prewarming
                    loadingMessage = "Preparando modelo..."
                } else {
                    loadingProgress = 0.5
                    loadingMessage = "Cargando en memoria..."
                }

                // Inicializar WhisperKit (descarga automaticamente si no existe)
                whisperKit = try await WhisperKit(config)

                loadingState = .ready
                loadingMessage = "Modelo listo ✓"
                loadingProgress = 1.0

                currentModel = model
                currentModelName = model.displayName
                isModelLoaded = true
                
                // Marcar como descargado para actualizar la UI
                markAsDownloaded(model)

                print("Modelo WhisperKit cargado exitosamente: \(model.displayName)")
                return // Exito, salir del bucle
                
            } catch {
                lastError = error
                let errorDesc = error.localizedDescription
                
                // Verificar si es error de red para reintentar
                let isNetworkError = errorDesc.contains("network") ||
                                    errorDesc.contains("-1005") ||
                                    errorDesc.contains("connection") ||
                                    errorDesc.contains("NSURLErrorDomain")
                
                if isNetworkError && attempt < maxRetries {
                    print("Error de red, reintentando... (intento \(attempt)/\(maxRetries))")
                    loadingMessage = "Error de conexion. Reintentando..."
                    continue // Reintentar
                } else {
                    // Error no recuperable o ultimo intento
                    break
                }
            }
        }
        
        // Si llegamos aqui, todos los intentos fallaron
        let errorMsg = lastError?.localizedDescription ?? "Error desconocido"
        errorMessage = "Error cargando modelo: \(errorMsg)"
        print("Error cargando WhisperKit despues de \(maxRetries) intentos: \(errorMsg)")
        throw WhisperKitError.modelLoadFailed(errorMsg)
        
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

    // MARK: - Model Storage Management

    /// Set de modelos que sabemos que estan descargados
    @Published var downloadedModels: Set<WhisperKitModel> = []

    /// Obtiene los posibles directorios donde WhisperKit guarda los modelos
    private var possibleModelDirectories: [URL] {
        var dirs: [URL] = []
        
        // Directorio de cache de HuggingFace
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            dirs.append(cacheDir.appendingPathComponent("huggingface/hub"))
        }
        
        // Directorio de Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(appSupport.appendingPathComponent("huggingface/hub"))
        }
        
        // Home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(homeDir.appendingPathComponent(".cache/huggingface/hub"))
        
        return dirs
    }

    /// Verifica si un modelo esta descargado localmente
    func isModelDownloaded(_ model: WhisperKitModel) -> Bool {
        // Primero revisar el cache
        if downloadedModels.contains(model) {
            return true
        }
        
        // El modelo que esta cargado siempre esta descargado
        if currentModel == model && isModelLoaded {
            downloadedModels.insert(model)
            return true
        }
        
        // Buscar en todos los directorios posibles
        let modelName = model.rawValue.replacingOccurrences(of: "openai_whisper-", with: "").lowercased()
        
        for modelsDir in possibleModelDirectories {
            guard FileManager.default.fileExists(atPath: modelsDir.path) else { continue }
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)
                // Buscar carpeta que contenga whisperkit y el nombre del modelo
                let found = contents.contains { url in
                    let name = url.lastPathComponent.lowercased()
                    return name.contains("whisperkit") && name.contains(modelName)
                }
                
                if found {
                    downloadedModels.insert(model)
                    return true
                }
            } catch {
                continue
            }
        }
        
        return false
    }
    
    /// Marca un modelo como descargado (llamar despues de cargar exitosamente)
    func markAsDownloaded(_ model: WhisperKitModel) {
        downloadedModels.insert(model)
        saveDownloadedModelsToStorage()
        print("📦 Modelo marcado como descargado: \(model.displayName)")
    }
    
    /// Actualiza la lista de modelos descargados
    func refreshDownloadedModels() {
        downloadedModels.removeAll()
        for model in WhisperKitModel.allCases {
            _ = isModelDownloaded(model)
        }
    }

    /// Obtiene el tamano de un modelo descargado en bytes
    func downloadedModelSize(_ model: WhisperKitModel) -> Int64? {
        let modelName = model.rawValue.replacingOccurrences(of: "openai_whisper-", with: "").lowercased()
        
        for modelsDir in possibleModelDirectories {
            guard FileManager.default.fileExists(atPath: modelsDir.path) else { continue }
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)
                
                for url in contents {
                    let name = url.lastPathComponent.lowercased()
                    if name.contains("whisperkit") && name.contains(modelName) {
                        return directorySize(at: url)
                    }
                }
            } catch {
                continue
            }
        }
        
        return nil
    }

    /// Calcula el tamano de un directorio recursivamente
    private func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(resourceValues.fileSize ?? 0)
            } catch {
                continue
            }
        }
        
        return totalSize
    }

    /// Borra un modelo descargado para liberar espacio
    /// Nota: Los modelos de WhisperKit usan el cache de CoreML de Apple
    /// que se gestiona automaticamente. Esta funcion solo desmarca el modelo
    /// y lo descarga de memoria.
    func deleteDownloadedModel(_ model: WhisperKitModel) -> Bool {
        // Si el modelo esta cargado actualmente, descargarlo de memoria
        if currentModel == model {
            unloadModel()
        }
        
        // Crear nuevo Set sin el modelo (fuerza actualizacion de SwiftUI)
        var newSet = downloadedModels
        newSet.remove(model)
        downloadedModels = newSet
        
        saveDownloadedModelsToStorage()
        
        print("🗑️ Modelo desmarcado como descargado: \(model.displayName)")
        
        return true
    }

    /// Obtiene informacion de todos los modelos descargados
    func getDownloadedModelsInfo() -> [(model: WhisperKitModel, size: Int64)] {
        var result: [(WhisperKitModel, Int64)] = []
        
        for model in WhisperKitModel.allCases {
            if isModelDownloaded(model), let size = downloadedModelSize(model) {
                result.append((model, size))
            }
        }
        
        return result
    }

    /// Formatea bytes a string legible (MB/GB)
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
