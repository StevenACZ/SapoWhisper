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
    let googleCloudTranscriber = GoogleCloudTranscriber()
    let hotkeyManager = HotkeyManager.shared
    let overlayManager = OverlayWindowManager.shared
    let deepgramTranscriber = DeepgramStreamingTranscriber()
    private let historyManager = TranscriptionHistoryManager.shared

    // Retry support
    @Published var lastFailedAudioURL: URL?
    private var lastFailedHistoryId: Int64?

    // Auto-stop timers
    private var autoStopTimer: Timer?
    private static let googleCloudMaxDuration: TimeInterval = 58 // Stop before 60s limit
    private static let stopTailPadding: TimeInterval = 0.12
    private var isStopPending = false

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
        setupOverlayCallbacks()
        _ = SoundManager.shared
        overlayManager.prewarm()

        // Cargar modelo automaticamente si el motor es WhisperLocal
        if currentEngine == .whisperLocal {
            Task {
                await loadWhisperKitModel()
            }
        }

    }

    /// Configura callbacks del overlay (pause/resume/retry)
    private func setupOverlayCallbacks() {
        overlayManager.onPauseToggle = { [weak self] in
            Task { @MainActor in
                self?.togglePause()
            }
        }
        overlayManager.onRetry = { [weak self] in
            Task { @MainActor in
                self?.retryTranscription()
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

        // Observar estado de transcripcion (Google Cloud)
        googleCloudTranscriber.$isTranscribing
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
        // Sincronizar estado con MenuBarIcon y DockIcon
        $appState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.objectWillChange.send()
                // Actualizar icono del Dock usando el manager
                DockIconManager.shared.updateIcon(for: state, isModelLoading: self?.isLoadingWhisperKit ?? false)
            }
            .store(in: &cancellables)
        
        // Observar carga de modelos para el icono del Dock
        whisperKitTranscriber.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self = self else { return }
                
                // Solo actualizar si estamos usando WhisperKit
                if self.currentEngine == .whisperLocal {
                    DockIconManager.shared.updateIcon(for: self.appState, isModelLoading: isLoading)
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

        // Observar cambios de idioma
        LocalizationManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observar nivel de audio del recorder para el overlay
        audioRecorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.overlayManager.updateAudioLevel(level)
            }
            .store(in: &cancellables)

        // Update overlay duration during recording
        audioRecorder.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self = self else { return }
                switch self.overlayManager.state {
                case .recording:
                    self.overlayManager.updateRecordingDuration(duration)
                case .paused:
                    break // Don't update timer during pause
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Observe device changes for visual notification
        AudioDeviceManager.shared.$detectedDeviceName
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deviceName in
                self?.overlayManager.showDeviceDetected(deviceName: deviceName)
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
        case .googleCloud:
            if googleCloudTranscriber.isConfigured {
                appState = .idle
            } else {
                appState = .noModel
            }
        case .deepgram:
            if deepgramTranscriber.isConfigured {
                appState = .idle
            } else {
                appState = .noModel
            }
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
                appState = .error("Error de conexión. Usando Apple Speech temporalmente.")
                
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
        let previousEngine = currentEngine
        selectedEngine = engine.rawValue

        if previousEngine == .whisperLocal && engine != .whisperLocal {
            whisperKitTranscriber.unloadModel()
        }

        checkInitialState()

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
            requestStopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    /// Toggle de pausa/resume (llamado por el botón del overlay)
    func togglePause() {
        guard audioRecorder.isRecording else { return }

        if audioRecorder.isPaused {
            // Resume
            do {
                try audioRecorder.resumeRecording()
                overlayManager.updateState(.recording(duration: audioRecorder.recordingDuration))
            } catch {
                print("Error resuming recording: \(error)")
            }
        } else {
            // Pause
            audioRecorder.pauseRecording()
            overlayManager.updateState(.paused(duration: audioRecorder.recordingDuration))
            overlayManager.updateAudioLevel(0)
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
        case .googleCloud:
            isReady = googleCloudTranscriber.isConfigured
        case .deepgram:
            isReady = deepgramTranscriber.isConfigured
        }

        guard isReady else {
            appState = .noModel
            return
        }

        // Guardar la app activa para volver a ella despues de pegar
        PasteManager.savePreviousApp()

        // Mostrar overlay PRIMERO para feedback visual inmediato
        let engine = currentEngine
        let hotkeyTime = CFAbsoluteTimeGetCurrent()
        appState = .recording

        overlayManager.updateState(.recording(duration: 0))
        print("⏱️ [hotkey→overlay] \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - hotkeyTime) * 1000))ms")

        // Start audio immediately after showing the prewarmed overlay.
        // The overlay is already on-screen at this point, so we prefer lower input latency.
        let mic = selectedMicrophone
        let playSound = playSoundEnabled
        startRecordingSession(
            engine: engine,
            microphone: mic,
            playSound: playSound,
            hotkeyTime: hotkeyTime
        )
    }
    
    private func requestStopRecordingAndTranscribe() {
        guard !isStopPending else { return }
        isStopPending = true

        let tailPadding = Self.stopTailPadding
        let stopRequestedAt = CFAbsoluteTimeGetCurrent()
        print("⏱️ [stop request] tail padding \(String(format: "%.0f", tailPadding * 1000))ms")

        Task {
            try? await Task.sleep(nanoseconds: UInt64(tailPadding * 1_000_000_000))
            await MainActor.run {
                self.stopRecordingAndTranscribe(stopRequestedAt: stopRequestedAt)
            }
        }
    }

    /// Detiene la grabacion y transcribe
    private func stopRecordingAndTranscribe(stopRequestedAt: CFAbsoluteTime) {
        isStopPending = false
        // Detener timers
        autoStopTimer?.invalidate()
        autoStopTimer = nil

        if playSoundEnabled {
            SoundManager.shared.play(.stopRecording)
        }

        let engine = currentEngine
        let language = selectedLanguage
        let duration = recordingDuration

        // All engines: stop recording, get audio file, transcribe
        guard let audioURL = audioRecorder.stopRecording() else {
            appState = .error("error.no_audio".localized)
            overlayManager.showError(message: "error.no_audio".localized)
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            return
        }

        let stopTime = CFAbsoluteTimeGetCurrent()
        print("⏱️ [stop request→actual stop] \(String(format: "%.0f", (stopTime - stopRequestedAt) * 1000))ms")
        print("⏱️ [stop] recording stopped, starting transcription with \(engine.displayName)...")
        appState = .processing

        // Actualizar overlay a transcribing
        overlayManager.updateState(.transcribing)

        Task {
            do {
                let transcription: String

                switch engine {
                case .appleOnline:
                    transcription = try await transcriber.transcribe(audioURL: audioURL, language: language)
                case .whisperLocal:
                    transcription = try await whisperKitTranscriber.transcribe(audioURL: audioURL, language: language)
                case .googleCloud:
                    transcription = try await googleCloudTranscriber.transcribe(audioURL: audioURL, language: language)
                case .deepgram:
                    transcription = try await deepgramTranscriber.transcribe(audioURL: audioURL, language: language)
                }

                let transcribeElapsed = (CFAbsoluteTimeGetCurrent() - stopTime) * 1000
                print("⏱️ [stop→result] \(String(format: "%.0f", transcribeElapsed))ms total transcription")

                lastTranscription = transcription
                PasteManager.copyToClipboard(transcription)
                overlayManager.showCompleted(text: transcription, autoDismissAfter: 2.0)

                if autoPasteEnabled {
                    PasteManager.simulatePaste()
                }
                print("⏱️ [stop→paste] \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - stopTime) * 1000))ms total")

                appState = .idle
                if playSoundEnabled {
                    SoundManager.shared.play(.success)
                }

                // Save to history and clean up
                historyManager.save(engine: engine.rawValue, language: language, duration: duration, text: transcription)
                audioRecorder.deleteRecording(at: audioURL)
                lastFailedAudioURL = nil
                print("Transcripcion completada (\(engine.displayName)): \(transcription.prefix(50))...")

            } catch {
                appState = .error(error.localizedDescription)
                overlayManager.showError(message: error.localizedDescription)
                if playSoundEnabled {
                    SoundManager.shared.play(.error)
                }

                // Save audio for retry
                if let savedPath = historyManager.saveAudioFile(from: audioURL) {
                    lastFailedHistoryId = historyManager.save(engine: engine.rawValue, language: language, duration: duration, text: "", audioPath: savedPath, status: "failed")
                    lastFailedAudioURL = URL(fileURLWithPath: savedPath)
                }
                audioRecorder.deleteRecording(at: audioURL)
                print("Error en transcripcion: \(error)")
            }
        }
    }

    /// Starts auto-stop timer for engines with duration limits
    private func startAutoStopTimer(for engine: TranscriptionEngine) {
        autoStopTimer?.invalidate()

        let maxDuration: TimeInterval
        switch engine {
        case .googleCloud:
            maxDuration = Self.googleCloudMaxDuration
        default:
            return // No limit for Apple/WhisperKit
        }

        // Fix #18: Tighter check interval
        autoStopTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAutoStopTick(maxDuration: maxDuration)
            }
        }
    }

    private func handleAutoStopTick(maxDuration: TimeInterval) {
        guard audioRecorder.isRecording else {
            autoStopTimer?.invalidate()
            autoStopTimer = nil
            return
        }

        if recordingDuration >= maxDuration {
            autoStopTimer?.invalidate()
            autoStopTimer = nil
            requestStopRecordingAndTranscribe()
        }
    }

    /// Retry transcription with the last failed audio (fix #19: smart engine fallback)
    func retryTranscription() {
        guard let audioURL = lastFailedAudioURL else { return }

        appState = .processing
        overlayManager.updateState(.transcribing)

        let engine = currentEngine
        let language = selectedLanguage

        Task {
            do {
                let transcription: String
                switch engine {
                case .appleOnline:
                    transcription = try await transcriber.transcribe(audioURL: audioURL, language: language)
                case .whisperLocal:
                    transcription = try await whisperKitTranscriber.transcribe(audioURL: audioURL, language: language)
                case .googleCloud:
                    transcription = try await googleCloudTranscriber.transcribe(audioURL: audioURL, language: language)
                case .deepgram:
                    transcription = try await deepgramTranscriber.transcribe(audioURL: audioURL, language: language)
                }

                lastTranscription = transcription
                PasteManager.copyToClipboard(transcription)
                overlayManager.showCompleted(text: transcription, autoDismissAfter: 2.0)

                if autoPasteEnabled {
                    PasteManager.simulatePaste()
                }

                appState = .idle
                if playSoundEnabled { SoundManager.shared.play(.success) }

                // Update history entry
                if let historyId = lastFailedHistoryId {
                    historyManager.updateStatus(id: historyId, status: "completed", transcription: transcription)
                }
                lastFailedAudioURL = nil
                lastFailedHistoryId = nil

            } catch {
                appState = .error(error.localizedDescription)
                overlayManager.showError(message: error.localizedDescription)
                if playSoundEnabled { SoundManager.shared.play(.error) }
            }
        }
    }
    
    // MARK: - Hotkey
    
    private func setupHotkey() {
        hotkeyManager.registerHotkey { [weak self] in
            let callbackTime = CFAbsoluteTimeGetCurrent()
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    print("⏱️ [hotkey callback] already on main in 0ms")
                    self?.toggleRecording()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let hopElapsed = (CFAbsoluteTimeGetCurrent() - callbackTime) * 1000
                        print("⏱️ [hotkey callback] hopped to main in \(String(format: "%.0f", hopElapsed))ms")
                        self?.toggleRecording()
                    }
                }
            }
        }
    }

    private func startRecordingSession(
        engine: TranscriptionEngine,
        microphone: String,
        playSound: Bool,
        hotkeyTime: CFAbsoluteTime
    ) {
        let audioStart = CFAbsoluteTimeGetCurrent()
        print("⏱️ [overlay→audio] deferred by \(String(format: "%.0f", (audioStart - hotkeyTime) * 1000))ms")

        do {
            audioRecorder.selectedDeviceUID = microphone
            try audioRecorder.startRecording()
            let recorderReady = CFAbsoluteTimeGetCurrent()
            print("⏱️ [audio engine] started in \(String(format: "%.0f", (recorderReady - audioStart) * 1000))ms")

            startAutoStopTimer(for: engine)
            print("⏱️ [level meter] using recorder tap (no extra engine)")

            if playSound {
                SoundManager.shared.play(.startRecording)
            }
            print("⏱️ [total startup] \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - hotkeyTime) * 1000))ms from hotkey")
        } catch {
            appState = .error(error.localizedDescription)
            overlayManager.showError(message: error.localizedDescription)
            if playSound {
                SoundManager.shared.play(.error)
            }
            print("Error al iniciar grabacion: \(error)")
        }
    }
    
    /// Texto del estado actual
    var statusText: String {
        switch appState {
        case .recording:
            let duration = Int(recordingDuration)
            return "menu.recording".localized(String(duration))
        default:
            return appState.statusText
        }
    }
    
    /// Texto del botón de grabación
    var recordButtonText: String {
        audioRecorder.isRecording ? "menu.stop_recording".localized : "menu.start_recording".localized
    }
    
    /// Si el boton de grabar esta habilitado
    var canRecord: Bool {
        switch currentEngine {
        case .appleOnline:
            return transcriber.isModelLoaded && !transcriber.isTranscribing
        case .whisperLocal:
            return whisperKitTranscriber.isModelLoaded && !whisperKitTranscriber.isTranscribing
        case .googleCloud:
            return googleCloudTranscriber.isConfigured && !googleCloudTranscriber.isTranscribing
        case .deepgram:
            return deepgramTranscriber.isConfigured && !deepgramTranscriber.isTranscribing
        }
    }
    
    /// Formatea la duración de grabación
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
