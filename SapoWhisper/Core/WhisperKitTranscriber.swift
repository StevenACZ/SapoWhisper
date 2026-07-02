//
//  WhisperKitTranscriber.swift
//  SapoWhisper
//
//
//  Transcriptor local usando WhisperKit (optimizado para Apple Silicon)
//

import Combine
import Foundation
import os

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

    /// R4: model being loaded by the in-flight task, so a second `loadModel`
    /// for the same model awaits it instead of cancelling and restarting.
    private var loadingModel: WhisperKitModel?
    private var idleUnloadTimer: Timer?

    /// Key para guardar modelos descargados en UserDefaults
    private let downloadedModelsKey = "whisperkit_downloaded_models"

    // MARK: - Initialization

    init() {
        SapoLog.recording.info("WhisperKitTranscriber initialized")
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
            SapoLog.recording.info(
                "WhisperKit downloaded models loaded count=\(self.downloadedModels.count, privacy: .public)"
            )
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

            if currentModel == model, isModelLoaded, !isLoading {
                return
            }

            // R4: a load already in flight for this model is awaited, not
            // cancelled — the on-demand reload path may race the kick-off.
            if loadingModel == model, let inFlight = loadTask {
                try await inFlight.value
                return
            }

            // Cancelar tarea anterior si existe
            if let existingTask = loadTask {
                SapoLog.recording.info("Cancelling previous WhisperKit load")
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
            loadingModel = model

            // Esperar a que termine (si lanza error, se propaga)
            defer { loadingModel = nil }
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
                SapoLog.recording.info(
                    "Loading WhisperKit model=\(model.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)/\(maxRetries, privacy: .public)"
                )

                if attempt > 1 {
                    loadingState = .downloading
                    loadingMessage = "Reintentando descarga (\(attempt)/\(maxRetries))..."
                    // Esperar antes de reintentar (delay incremental)
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)  // 2s, 4s, 6s
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
                        var sizeStableCount = 0  // Contador para detectar cuando el tamano deja de cambiar

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
                                                SapoLog.recording.debug(
                                                    "WhisperKit download progress percent=\(Int(currentProgress * 100), privacy: .public)"
                                                )
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
                noteActivityForIdleUnload()

                // Marcar como descargado para actualizar la UI
                markAsDownloaded(model)

                SapoLog.recording.info(
                    "WhisperKit model loaded model=\(model.rawValue, privacy: .public)"
                )
                return  // Exito, salir del bucle

            } catch {
                lastError = error
                let errorDesc = error.localizedDescription

                // Verificar si es error de red para reintentar
                let isNetworkError =
                    errorDesc.contains("network") || errorDesc.contains("-1005") || errorDesc.contains("connection")
                    || errorDesc.contains("NSURLErrorDomain") || errorDesc.contains("offline")

                if isNetworkError && attempt < maxRetries {
                    SapoLog.recording.warning(
                        "WhisperKit network error retry=\(attempt, privacy: .public)/\(maxRetries, privacy: .public)"
                    )
                    loadingMessage = "Problema de conexión. Reintentando (\(attempt)/\(maxRetries))..."
                    continue  // Reintentar
                } else {
                    // Error no recuperable o ultimo intento
                    break
                }
            }
        }

        // Si llegamos aqui, todos los intentos fallaron
        let errorMsg = lastError?.localizedDescription ?? "Error desconocido"

        // Traducir errores comunes de inglés a español para el usuario
        var userFriendlyError = errorMsg
        if errorMsg.contains("network") || errorMsg.contains("connection") || errorMsg.contains("offline") {
            userFriendlyError = "No se pudo conectar a internet para descargar el modelo."
        } else if errorMsg.contains("space") || errorMsg.contains("disk") {
            userFriendlyError = "No hay suficiente espacio en disco."
        }

        errorMessage = "Error cargando modelo: \(userFriendlyError)"
        SapoLog.recording.error(
            "WhisperKit load failed after \(maxRetries, privacy: .public) attempts: \(errorMsg, privacy: .public)"
        )
        throw WhisperKitError.modelLoadFailed(userFriendlyError)
    }

    /// Descarga el modelo actual de memoria
    func unloadModel() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil
        loadTask?.cancel()
        loadTask = nil
        #if canImport(WhisperKit)
            whisperKit = nil
        #endif
        isModelLoaded = false
        isLoading = false
        isTranscribing = false
        loadingProgress = 0
        loadingMessage = ""
        loadingState = .idle
        currentModel = nil
        currentModelName = nil
        SapoLog.recording.info("WhisperKit model unloaded")
    }

    // MARK: - R4: idle unload

    /// Re-arms the idle timer after model activity (load, transcription).
    /// With the setting at 0 (default) the model stays pinned in RAM.
    func noteActivityForIdleUnload() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil

        let minutes = UserDefaults.standard.integer(forKey: Constants.StorageKeys.whisperKitUnloadAfterMinutes)
        guard minutes > 0, isModelLoaded else { return }

        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                self?.unloadAfterIdle(configuredMinutes: minutes)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        idleUnloadTimer = timer
    }

    private func unloadAfterIdle(configuredMinutes: Int) {
        guard isModelLoaded, !isTranscribing, !isLoading else {
            // Busy right at the deadline: try again on the next activity tick.
            noteActivityForIdleUnload()
            return
        }
        SapoLog.performance.info(
            "WhisperKit model unloaded after idle minutes=\(configuredMinutes, privacy: .public)"
        )
        unloadModel()
    }

    // MARK: - Transcription

    /// Transcribe un archivo de audio usando WhisperKit
    func transcribe(audioURL: URL, language: String = "es") async throws -> String {
        #if canImport(WhisperKit)
            guard isModelLoaded, let whisperKit = whisperKit else {
                throw WhisperKitError.modelNotLoaded
            }

            // Defense-in-depth: WhisperKit wraps a single model instance and is
            // not reentrant. The live-dictation hotkey gate already blocks a
            // colliding start, but a history retranscribe reaches this method on
            // a different path, so guard here so two inferences can never hit the
            // same model concurrently (corrupted output / crash).
            guard !isTranscribing else {
                throw WhisperKitError.transcriptionInProgress
            }

            isTranscribing = true
            progress = 0
            errorMessage = nil

            defer {
                isTranscribing = false
                progress = 1.0
                noteActivityForIdleUnload()
            }

            do {
                SapoLog.recording.info(
                    "WhisperKit transcription started file=\(audioURL.lastPathComponent, privacy: .public)"
                )
                progress = 0.1

                // Configurar opciones de decodificacion
                var options = DecodingOptions()
                options.language = TranscriptionLanguageCatalog.whisperLanguageCode(for: language)

                // Whisper-style initial prompt: condition the decoder on the
                // user's canonical vocabulary so keyterms come out spelled
                // right on the first pass. WhisperKit trims to its max prompt
                // length and strips special tokens internally.
                let vocabularyPrompt = VocabularyManager.shared.initialPromptText()
                if !vocabularyPrompt.isEmpty, let tokenizer = whisperKit.tokenizer {
                    let promptTokens = tokenizer.encode(text: " " + vocabularyPrompt)
                        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    if !promptTokens.isEmpty {
                        options.promptTokens = promptTokens
                        SapoLog.recording.info(
                            "WhisperKit vocabulary prompt attached tokens=\(promptTokens.count, privacy: .public)"
                        )
                    }
                }

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

                SapoLog.recording.info(
                    "WhisperKit transcription complete chars=\(transcription.count, privacy: .public)"
                )
                return transcription

            } catch {
                errorMessage = "Error en transcripcion: \(error.localizedDescription)"
                SapoLog.recording.error(
                    "WhisperKit transcription failed error=\(error.localizedDescription, privacy: .public)"
                )
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
        SapoLog.recording.info(
            "WhisperKit model marked downloaded=\(model.rawValue, privacy: .public)"
        )
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
        guard
            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [],  // No skippear hidden files
                errorHandler: nil
            )
        else {
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

        SapoLog.recording.info(
            "WhisperKit delete model=\(model.rawValue, privacy: .public) keyword=\(modelName, privacy: .public)"
        )

        var foundAndDeleted = false

        for modelsDir in possibleModelDirectories {
            // Check if dir exists
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: modelsDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)

                for url in contents {
                    let name = url.lastPathComponent.lowercased()

                    // La coincidencia debe ser mas flexible
                    // Si contiene "models--" y ("whisper" + modelName)
                    let matches = name.contains("whisper") && name.contains(modelName)

                    if matches {
                        do {
                            try FileManager.default.removeItem(at: url)
                            SapoLog.recording.info(
                                "WhisperKit deleted file=\(url.lastPathComponent, privacy: .public)"
                            )
                            foundAndDeleted = true
                        } catch {
                            SapoLog.recording.error(
                                "WhisperKit delete failed file=\(url.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                            )
                        }
                    }
                }
            } catch {
                SapoLog.recording.warning(
                    "WhisperKit scan failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if !foundAndDeleted {
            SapoLog.recording.warning(
                "WhisperKit no files found to delete for model=\(model.rawValue, privacy: .public)"
            )
        }

        // Crear nuevo Set sin el modelo (fuerza actualizacion de SwiftUI)
        var newSet = downloadedModels
        newSet.remove(model)
        downloadedModels = newSet

        saveDownloadedModelsToStorage()

        SapoLog.recording.info(
            "WhisperKit model unmarked model=\(model.rawValue, privacy: .public)"
        )

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
    case transcriptionInProgress

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
        case .transcriptionInProgress:
            return "Ya hay una transcripcion en curso"
        }
    }
}

// MARK: - TranscriptionEngineSession

extension WhisperKitTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isModelLoaded }
    var isBusy: Bool { isTranscribing }
}
