//
//  SapoWhisperViewModel.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Combine

/// ViewModel principal que coordina toda la funcionalidad de la app
@MainActor
class SapoWhisperViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var appState: AppState = .idle
    @Published private(set) var lastTranscription: String = ""
    @Published var showSettings = false
    @Published var autoPasteEnabled = true
    @Published var recordingDuration: TimeInterval = 0

    // Motor de transcripcion
    @Published var isLoadingWhisperKit = false
    @Published var whisperKitLoadingProgress: Double = 0
    @Published var whisperKitLoadingMessage: String = ""

    // MARK: - AppStorage Properties

    @AppStorage(Constants.StorageKeys.language) var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.playSound) var playSoundEnabled = true
    @AppStorage(Constants.StorageKeys.transcriptionEngine) var selectedEngine: String = TranscriptionEngine.appleOnline.rawValue
    @AppStorage(Constants.StorageKeys.whisperKitModel) var selectedWhisperModel: String = WhisperKitModel.small.rawValue

    // MARK: - Managers

    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let whisperKitTranscriber = WhisperKitTranscriber()
    let downloadManager = DownloadManager()
    let hotkeyManager = HotkeyManager.shared

    // MARK: - Computed Properties

    var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .appleOnline
    }

    var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }

    var isWhisperKitReady: Bool {
        whisperKitTranscriber.isModelLoaded
    }

    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization

    init() {
        setupBindings()
        checkInitialState()
        setupHotkey()
        loadSavedSettings()
        
        // Cargar modelo automaticamente si el motor es WhisperLocal
        if currentEngine == .whisperLocal {
            Task {
                await loadWhisperKitModel()
            }
        }
    }

    /// Carga las configuraciones guardadas
    private func loadSavedSettings() {
        // Aplicar micrófono guardado
        audioRecorder.selectedDeviceUID = selectedMicrophone

        // Aplicar hotkey guardado
        hotkeyManager.currentKeyCode = UInt32(hotkeyKeyCode)
        hotkeyManager.currentModifiers = UInt32(hotkeyModifiers)
    }
    
    private func setupBindings() {
        // Observar estado de grabacion
        audioRecorder.$isRecording
            .sink { [weak self] isRecording in
                if isRecording {
                    self?.appState = .recording
                }
            }
            .store(in: &cancellables)

        // Observar duracion de grabacion
        audioRecorder.$recordingDuration
            .sink { [weak self] duration in
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        // Observar estado de transcripcion (Apple)
        transcriber.$isTranscribing
            .sink { [weak self] isTranscribing in
                if isTranscribing {
                    self?.appState = .processing
                }
            }
            .store(in: &cancellables)

        // Observar estado de transcripcion (WhisperKit)
        whisperKitTranscriber.$isTranscribing
            .sink { [weak self] isTranscribing in
                if isTranscribing {
                    self?.appState = .processing
                }
            }
            .store(in: &cancellables)

        // Observar carga de WhisperKit
        whisperKitTranscriber.$isLoading
            .sink { [weak self] isLoading in
                self?.isLoadingWhisperKit = isLoading
            }
            .store(in: &cancellables)

        whisperKitTranscriber.$loadingProgress
            .sink { [weak self] progress in
                self?.whisperKitLoadingProgress = progress
            }
            .store(in: &cancellables)

        whisperKitTranscriber.$loadingMessage
            .sink { [weak self] message in
                self?.whisperKitLoadingMessage = message
            }
            .store(in: &cancellables)

        // Observar cuando el modelo esta listo (Apple)
        transcriber.$isModelLoaded
            .sink { [weak self] isLoaded in
                guard let self = self else { return }
                if isLoaded && !self.audioRecorder.isRecording && !self.transcriber.isTranscribing {
                    self.appState = .idle
                }
            }
            .store(in: &cancellables)

        // Observar cuando el modelo esta listo (WhisperKit)
        whisperKitTranscriber.$isModelLoaded
            .sink { [weak self] isLoaded in
                guard let self = self else { return }
                if self.currentEngine == .whisperLocal && isLoaded {
                    self.appState = .idle
                }
            }
            .store(in: &cancellables)
        // Observar cambios en modelos descargados (para actualizar UI al borrar)
        whisperKitTranscriber.$downloadedModels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Initial State

    private func checkInitialState() {
        switch currentEngine {
        case .appleOnline:
            if transcriber.isModelLoaded {
                appState = .idle
            } else {
                appState = .noModel
            }
        case .whisperLocal:
            if whisperKitTranscriber.isModelLoaded {
                appState = .idle
            } else {
                appState = .noModel
            }
        }
    }

    /// Descarga un modelo de Whisper (legacy)
    func downloadModel(_ model: WhisperModel) {
        downloadManager.downloadModel(model)
    }

    /// Carga un modelo despues de configurarlo (legacy)
    func loadModel(_ model: WhisperModel) async {
        do {
            try await transcriber.loadModel(model)
            appState = .idle
        } catch {
            appState = .error(error.localizedDescription)
        }
    }

    // MARK: - WhisperKit Methods

    /// Carga el modelo de WhisperKit seleccionado
    /// Si falla, hace fallback automatico a Apple Speech
    func loadWhisperKitModel() async {
        do {
            try await whisperKitTranscriber.loadModel(currentWhisperKitModel, language: selectedLanguage)
            appState = .idle
        } catch {
            let errorMsg = error.localizedDescription
            print("❌ Error cargando WhisperKit: \(errorMsg)")
            
            // Verificar si es error de red
            let isNetworkError = errorMsg.contains("network") ||
                                errorMsg.contains("-1005") ||
                                errorMsg.contains("connection") ||
                                errorMsg.contains("NSURLErrorDomain") ||
                                errorMsg.contains("lost")
            
            if isNetworkError {
                // Fallback a Apple Speech
                print("🔄 Haciendo fallback a Apple Speech por error de red...")
                selectedEngine = TranscriptionEngine.appleOnline.rawValue
                appState = .error("Error de red descargando modelo. Usando Apple Speech temporalmente.")
                
                // Pequeno delay para mostrar el error, luego limpiar
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 segundos
                    if case .error(_) = self.appState {
                        self.appState = .idle
                    }
                }
            } else {
                appState = .error("Error cargando modelo: \(errorMsg)")
            }
        }
    }

    /// Cambia el motor de transcripcion
    func setEngine(_ engine: TranscriptionEngine) {
        selectedEngine = engine.rawValue

        // Si cambia a WhisperKit y no hay modelo cargado, intentar cargarlo
        if engine == .whisperLocal && !whisperKitTranscriber.isModelLoaded {
            Task {
                await loadWhisperKitModel()
            }
        }
    }

    /// Cambia el modelo de WhisperKit
    func setWhisperKitModel(_ model: WhisperKitModel) {
        selectedWhisperModel = model.rawValue

        // Si el motor actual es WhisperKit, recargar el modelo
        if currentEngine == .whisperLocal {
            whisperKitTranscriber.unloadModel()
            Task {
                await loadWhisperKitModel()
            }
        }
    }
    
    // MARK: - Recording & Transcription
    
    /// Toggle de grabación (llamado por hotkey o botón)
    func toggleRecording() {
        if audioRecorder.isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }
    
    /// Inicia la grabacion
    func startRecording() {
        // Verificar que el motor actual tiene modelo cargado
        let isReady: Bool
        switch currentEngine {
        case .appleOnline:
            isReady = transcriber.isModelLoaded
        case .whisperLocal:
            isReady = whisperKitTranscriber.isModelLoaded
        }

        guard isReady else {
            appState = .noModel
            return
        }

        // Guardar la app activa para volver a ella despues de pegar
        PasteManager.savePreviousApp()

        do {
            // Actualizar microfono seleccionado antes de grabar
            audioRecorder.selectedDeviceUID = selectedMicrophone
            try audioRecorder.startRecording()
            appState = .recording
            if playSoundEnabled {
                SoundManager.shared.play(.startRecording)
            }
            print("Grabacion iniciada (Motor: \(currentEngine.displayName))")
        } catch {
            appState = .error(error.localizedDescription)
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            print("Error al iniciar grabacion: \(error)")
        }
    }
    
    /// Detiene la grabacion y transcribe
    func stopRecordingAndTranscribe() {
        if playSoundEnabled {
            SoundManager.shared.play(.stopRecording)
        }

        guard let audioURL = audioRecorder.stopRecording() else {
            appState = .error("No se pudo obtener el audio")
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            return
        }

        print("Grabacion detenida, iniciando transcripcion con \(currentEngine.displayName)...")
        appState = .processing

        // Capturar valores para usar en el Task
        let language = selectedLanguage
        let engine = currentEngine

        Task {
            do {
                let transcription: String

                // Usar el motor correspondiente
                switch engine {
                case .appleOnline:
                    transcription = try await transcriber.transcribe(audioURL: audioURL, language: language)
                case .whisperLocal:
                    transcription = try await whisperKitTranscriber.transcribe(audioURL: audioURL, language: language)
                }

                lastTranscription = transcription

                // Copiar al portapapeles
                PasteManager.copyToClipboard(transcription)

                // Auto-paste si esta habilitado
                if autoPasteEnabled {
                    // Pequeno delay para asegurar que el clipboard este listo
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    PasteManager.simulatePaste()
                }

                appState = .idle
                if playSoundEnabled {
                    SoundManager.shared.play(.success)
                }

                // Limpiar archivo temporal
                audioRecorder.deleteRecording(at: audioURL)
                print("Transcripcion completada (\(engine.displayName)): \(transcription.prefix(50))...")
            } catch {
                appState = .error(error.localizedDescription)
                if playSoundEnabled {
                    SoundManager.shared.play(.error)
                }
                print("Error en transcripcion: \(error)")
            }
        }
    }
    
    // MARK: - Hotkey
    
    private func setupHotkey() {
        hotkeyManager.registerHotkey { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
    }
    
    /// Texto del estado actual
    var statusText: String {
        switch appState {
        case .recording:
            let duration = Int(recordingDuration)
            return "Grabando... \(duration)s"
        default:
            return appState.statusText
        }
    }
    
    /// Texto del botón de grabación
    var recordButtonText: String {
        audioRecorder.isRecording ? "⏹ Detener" : "🎤 Grabar"
    }
    
    /// Si el boton de grabar esta habilitado
    var canRecord: Bool {
        switch currentEngine {
        case .appleOnline:
            return transcriber.isModelLoaded && !transcriber.isTranscribing
        case .whisperLocal:
            return whisperKitTranscriber.isModelLoaded && !whisperKitTranscriber.isTranscribing
        }
    }
    
    /// Formatea la duración de grabación
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
