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

    private var loadTask: Task<Void, Error>?

    // MARK: - Model Management

    /// Carga un modelo de WhisperKit
    /// WhisperKit descarga automaticamente el modelo si no existe localmente
    /// Incluye reintentos automaticos para manejar errores de red
    func loadModel(_ model: WhisperKitModel, language: String = "es") async throws {
        #if canImport(WhisperKit)
        
        // Cancelar tarea anterior si existe
        if let existingTask = loadTask {
            print("🛑 Cancelando carga anterior de WhisperKit...")
            existingTask.cancel()
            loadTask = nil
            // Esperar un momento a que limpie
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        
        // Crear nueva tarea de carga
        let task = Task {
            try await performLoadModel(model, language: language)
        }
        
        loadTask = task
        
        // Esperar a que termine (si lanza error, se propaga)
        try await task.value
        loadTask = nil
        
        #else
        throw WhisperKitError.notAvailable
        #endif
    }
    
    private func performLoadModel(_ model: WhisperKitModel, language: String) async throws {
        guard !isLoading else {
            // Esto solo pasa si se llamo internamente fuera del wrapper, por seguridad reseteamos
            isLoading = false
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

                // Tarea de monitoreo de progreso (SOLO SI NO ESTA DESCARGADO)
                var monitoringTask: Task<Void, Never>? = nil
                
                if !alreadyDownloaded {
                    monitoringTask = Task { @MainActor in
                        var lastProgress: Double = 0
                        
                        // Variables para velocidad y deteccion de fin de descarga
                        var lastCheckDate = Date()
                        var lastSessionBytes: Int64 = 0
                        var sizeStableCount = 0 // Contador para detectar cuando el tamano deja de cambiar
                        
                        // Obtener tamano inicial del REPO COMPLETO
                        let initialRepoSize = self.getTotalRepoSize() ?? 0
                        let expectedSize = Double(model.sizeInBytes)
                        
                        while !Task.isCancelled {
                            // 1. Obtener tamano actual
                            if let currentRepoSize = self.getTotalRepoSize() {
                                
                                let downloadedSessionBytes = max(0, currentRepoSize - initialRepoSize)
                                let currentProgress = min(Double(downloadedSessionBytes) / expectedSize, 0.99)
                                
                                // 2. Calcular velocidad (bytes por segundo)
                                let now = Date()
                                let timeDelta = now.timeIntervalSince(lastCheckDate)
                                
                                // Solo actualizar velocidad y logica de stabling cada 0.5s
                                if timeDelta >= 0.5 {
                                    let bytesDelta = downloadedSessionBytes - lastSessionBytes
                                    let speedBps = Double(bytesDelta) / timeDelta
                                    let speedMBps = speedBps / 1024 / 1024
                                    
                                    // Deteccion de estabilidad (Prewarming detectado)
                                    if bytesDelta == 0 && currentProgress > 0.85 {
                                        sizeStableCount += 1
                                    } else {
                                        sizeStableCount = 0
                                    }
                                    
                                    // Actualizar referencias para siguiente ciclo
                                    lastCheckDate = now
                                    lastSessionBytes = downloadedSessionBytes
                                    
                                    let downloadedMB = Int(downloadedSessionBytes / 1024 / 1024)
                                    let totalMB = Int(expectedSize / 1024 / 1024)
                                    let speedString = String(format: "%.1f MB/s", max(0, speedMBps))
                                    
                                    // 3. Actualizar UI
                                    if sizeStableCount >= 2 {
                                        self.loadingState = .prewarming
                                        self.loadingMessage = "Finalizando descarga y preparando..."
                                        self.loadingProgress = 1.0
                                    } else if currentProgress >= lastProgress || lastProgress == 0 {
                                        lastProgress = currentProgress
                                        self.loadingProgress = currentProgress
                                        
                                        if currentProgress >= 0.93 {
                                            self.loadingState = .prewarming
                                            self.loadingMessage = "Verificando archivos..."
                                        } else {
                                            self.loadingState = .downloading
                                            let percent = Int(currentProgress * 100)
                                            let msg = "Descargando... \(percent)% (\(downloadedMB)/\(totalMB) MB) • \(speedString)"
                                            self.loadingMessage = msg
                                            
                                            if Int(currentProgress * 100) % 5 == 0 {
                                                print("⬇️ \(msg)")
                                            }
                                        }
                                    }
                                }
                            }
                            
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                }
                
                // Asegurar cancelar monitoreo al terminar
                defer {
                    monitoringTask?.cancel()
                }

                // Configuracion de WhisperKit
                let config = WhisperKitConfig(
                    model: model.rawValue,
                    verbose: true,
                    prewarm: true
                )

                if !alreadyDownloaded {
                    loadingState = .downloading
                    loadingMessage = "Iniciando descarga..."
                } else {
                    loadingState = .prewarming
                    loadingMessage = "Cargando en memoria..."
                    loadingProgress = 0.5
                }

                // Inicializar WhisperKit (bloqueante hasta que descarga y carga)
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

        // Documents directory (Default WhisperKit location)
        if let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            dirs.append(docDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml"))
            // Tambien agregar la ruta raiz por si acaso
            dirs.append(docDir.appendingPathComponent("huggingface/models"))
        }
        
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
                
                for url in contents {
                    let name = url.lastPathComponent.lowercased()
                    
                    // Estrategia de coincidencia flexible
                    let matches = name.contains("whisper") && name.contains(modelName)
                    
                    if matches {
                        downloadedModels.insert(model)
                        return true
                    }
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

    /// Obtiene el directorio del repo de WhisperKit
    func getWhisperKitRepoDirectory() -> URL? {
        for modelsDir in possibleModelDirectories {
            guard FileManager.default.fileExists(atPath: modelsDir.path) else { continue }
            
            // Caso 1: El directorio mismo es el repo (ej: .../whisperkit-coreml)
            if modelsDir.lastPathComponent.lowercased().contains("whisperkit") {
                return modelsDir
            }
            
            // Caso 2: El directorio contiene el repo como subcarpeta
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)
                if let repoURL = contents.first(where: { $0.lastPathComponent.lowercased().contains("whisperkit") }) {
                    return repoURL
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Obtiene el tamano total del repo de WhisperKit (para monitorear descargas)
    func getTotalRepoSize() -> Int64? {
        guard let repoURL = getWhisperKitRepoDirectory() else { return nil }
        return directorySize(at: repoURL)
    }

    /// Obtiene el tamano de un modelo especifico descargado en bytes
    func downloadedModelSize(_ model: WhisperKitModel) -> Int64? {
        guard let repoURL = getWhisperKitRepoDirectory() else { return nil }
        
        // 1. Intentar busqueda exacta por nombre de modelo (ej: openai_whisper-tiny)
        let exactPath = repoURL.appendingPathComponent(model.rawValue)
        if FileManager.default.fileExists(atPath: exactPath.path) {
            return directorySize(at: exactPath)
        }
        
        // 2. Intentar busqueda flexible si el exacto falla (por si la estructura es distinta)
        let modelName = model.rawValue.replacingOccurrences(of: "openai_whisper-", with: "").lowercased()
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: repoURL, includingPropertiesForKeys: nil)
            for url in contents {
                let name = url.lastPathComponent.lowercased()
                if name.contains("whisper") && name.contains(modelName) {
                    return directorySize(at: url)
                }
            }
        } catch { return nil }
        
        return nil
    }

    /// Calcula el tamano de un directorio recursivamente
    private func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        // Usar enumerator con opciones para incluir archivos ocultos (.blobs, etc)
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [], // No skippear hidden files
            errorHandler: nil
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == true { continue }
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
        
        let modelName = model.rawValue.replacingOccurrences(of: "openai_whisper-", with: "").lowercased()
        // Buscamos algo que coincida con "whisperkit" y el nombre del modelo (ej: "small")
        // Los folders de HF son tipo: models--argmaxinc--whisperkit-coreml-openai-whisper-small
        
        print("🔍 Intentando borrar modelo: \(model.displayName) (buscando keywords: 'whisperkit' + '\(modelName)')")
        
        var foundAndDeleted = false
        
        for modelsDir in possibleModelDirectories {
            // Check if dir exists
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: modelsDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            
            print("📁 Escaneando directorio: \(modelsDir.path)")
            
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)
                
                for url in contents {
                    let name = url.lastPathComponent.lowercased()
                    // Debug log
                    // print("   - Encontrado: \(name)")
                    
                    // La coincidencia debe ser mas flexible
                    // Si contiene "models--" y ("whisper" + modelName)
                    let matches = name.contains("whisper") && name.contains(modelName)
                    
                    if matches {
                        do {
                            try FileManager.default.removeItem(at: url)
                            print("✅ BORRADO: \(url.lastPathComponent)")
                            foundAndDeleted = true
                        } catch {
                            print("❌ Error borrando \(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                print("⚠️ Error leyendo directorio \(modelsDir.path): \(error.localizedDescription)")
            }
        }
        
        if !foundAndDeleted {
            print("⚠️ No se encontraron archivos para borrar del modelo \(model.displayName)")
            print("   Rutas chequeadas: \(possibleModelDirectories.map { $0.path })")
        }
        
        // Crear nuevo Set sin el modelo (fuerza actualizacion de SwiftUI)
        var newSet = downloadedModels
        newSet.remove(model)
        downloadedModels = newSet
        
        saveDownloadedModelsToStorage()
        
        print("🗑️ Modelo desmarcado de la lista interna: \(model.displayName)")
        
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
