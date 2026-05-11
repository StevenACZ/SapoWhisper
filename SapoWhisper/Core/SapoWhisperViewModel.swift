//
//  SapoWhisperViewModel.swift
//  SapoWhisper
//
//

import Combine
import OSLog
import SwiftUI
import os

/// ViewModel principal que coordina toda la funcionalidad de la app
@MainActor
class SapoWhisperViewModel: ObservableObject {

    struct HistoryRetranscriptionResult {
        let entryId: Int64
        let errorMessage: String?
    }

    private struct PersistedHistoryEntry {
        let id: Int64
        let audioURL: URL?
        let copiedAudioToHistory: Bool
    }

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
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) var selectedDeepgramMode: String = DeepgramTranscriptionMode.nova3.rawValue
    @AppStorage(Constants.StorageKeys.deepgramPreviousLanguage) var deepgramPreviousLanguage: String = ""

    // MARK: - Managers

    let audioRecorder = AudioRecorder()
    let transcriber = WhisperTranscriber()
    let whisperKitTranscriber = WhisperKitTranscriber()
    let googleCloudTranscriber = GoogleCloudTranscriber()
    let hotkeyManager = HotkeyManager.shared
    let overlayManager = OverlayWindowManager.shared
    let deepgramTranscriber = DeepgramBatchTranscriber()
    let deepgramFluxTranscriber = DeepgramFluxLiveTranscriber()
    private let historyManager = TranscriptionHistoryManager.shared
    private let transcriptPostProcessor = TranscriptPostProcessor()

    // Retry support
    @Published var lastFailedAudioURL: URL?
    private var lastFailedHistoryId: Int64?

    // Auto-stop timers
    private var autoStopTimer: Timer?
    private static let googleCloudMaxDuration: TimeInterval = 58  // Stop before 60s limit
    private static let stopTailPadding: TimeInterval = 0.12
    private static let firstInputBufferTimeout: TimeInterval = 0.8
    private static let startRetryBudget: TimeInterval = 1.0
    private static let startRetryBackoffs: [TimeInterval] = [0.15, 0.30]
    private static let startHotkeyDebounce: TimeInterval = 0.35
    private var isStopPending = false
    private var startRecordingTask: Task<Void, Never>?
    private var isStartPending = false
    private var recordingSessionCounter: UInt64 = 0
    private var toggleRecordingCount: UInt64 = 0
    private var activeRecordingSessionID: UInt64?
    private var activeTranscriptionSessionID: UInt64?
    private var lastStartHotkeyTime: CFAbsoluteTime = 0
    private var shouldResumeMicMonitorAfterRecording = false

    // MARK: - Computed Properties

    var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .appleOnline
    }

    var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }

    var currentDeepgramMode: DeepgramTranscriptionMode {
        DeepgramTranscriptionMode(rawValue: selectedDeepgramMode) ?? .nova3
    }

    private var isDeepgramFluxLiveSelected: Bool {
        currentEngine == .deepgram && currentDeepgramMode == .fluxLive
    }

    private var isAnyRecorderActive: Bool {
        audioRecorder.isRecording || deepgramFluxTranscriber.isStreaming
    }

    var isWhisperKitReady: Bool {
        whisperKitTranscriber.isModelLoaded
    }

    func isEngineReady(_ engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .appleOnline:
            return true
        case .whisperLocal:
            return whisperKitTranscriber.isModelLoaded
        case .googleCloud:
            return googleCloudTranscriber.isConfigured
        case .deepgram:
            return deepgramTranscriber.isConfigured
        }
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
                guard self?.deepgramFluxTranscriber.isStreaming != true else { return }
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        deepgramFluxTranscriber.$isStreaming
            .sink { [weak self] isStreaming in
                if isStreaming {
                    self?.appState = .recording
                }
            }
            .store(in: &cancellables)

        deepgramFluxTranscriber.$recordingDuration
            .sink { [weak self] duration in
                guard self?.currentEngine == .deepgram else { return }
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
                // Actualizar icono del Dock usando el manager
                DockIconManager.shared.updateIcon(for: state, isModelLoading: self?.isLoadingWhisperKit ?? false)
                // Auto-Ducking: reducir/restaurar volumen del sistema
                AutoDuckingManager.shared.handleStateChange(state)
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

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.transcriber.refreshAuthorizationStatus()
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

        deepgramFluxTranscriber.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard self?.currentEngine == .deepgram else { return }
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
                    break  // Don't update timer during pause
                default:
                    break
                }
            }
            .store(in: &cancellables)

        deepgramFluxTranscriber.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self, self.currentEngine == .deepgram else { return }
                switch self.overlayManager.state {
                case .recording:
                    self.overlayManager.updateRecordingDuration(duration)
                case .paused:
                    break
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
            appState = .idle
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
            let isNetworkError =
                errorMsg.contains("network") || errorMsg.contains("-1005") || errorMsg.contains("connection")
                || errorMsg.contains("NSURLErrorDomain") || errorMsg.contains("lost")

            if isNetworkError {
                // Fallback a Apple Speech
                print("🔄 Haciendo fallback a Apple Speech por error de red...")
                selectedEngine = TranscriptionEngine.appleOnline.rawValue
                appState = .error("Error de conexión. Usando Apple Speech temporalmente.")

                // Pequeno delay para mostrar el error, luego limpiar
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 segundos
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

        applyDeepgramLanguagePolicy()

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

    func setDeepgramMode(_ mode: DeepgramTranscriptionMode) {
        selectedDeepgramMode = mode.rawValue
        applyDeepgramLanguagePolicy()
        checkInitialState()
    }

    private func applyDeepgramLanguagePolicy() {
        guard currentEngine == .deepgram else { return }

        switch currentDeepgramMode {
        case .fluxLive:
            if selectedLanguage != "auto" {
                deepgramPreviousLanguage = selectedLanguage
            }
            selectedLanguage = "auto"
        case .nova3:
            if selectedLanguage == "auto", !deepgramPreviousLanguage.isEmpty {
                selectedLanguage = deepgramPreviousLanguage
            }
            deepgramPreviousLanguage = ""
        }
    }

    // MARK: - Recording & Transcription

    /// Toggle de grabación (llamado por hotkey o botón)
    func toggleRecording() {
        toggleRecordingCount &+= 1
        let toggleCount = toggleRecordingCount
        SapoLog.hotkey.info(
            "Recording toggle requested count=\(toggleCount, privacy: .public) \(self.diagnosticContext(), privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-toggle",
            context: "count=\(toggleCount) \(diagnosticContext())",
            force: true
        )

        if isStartPending {
            SapoLog.hotkey.info("Recording toggle route=cancel-start count=\(toggleCount, privacy: .public)")
            cancelPendingRecordingStart()
        } else if deepgramFluxTranscriber.isStreaming {
            SapoLog.hotkey.info("Recording toggle route=stop-flux count=\(toggleCount, privacy: .public)")
            requestStopFluxRecordingAndTranscribe()
        } else if audioRecorder.isRecording {
            SapoLog.hotkey.info("Recording toggle route=stop-recorder count=\(toggleCount, privacy: .public)")
            requestStopRecordingAndTranscribe()
        } else if canStartRecordingFromHotkey() {
            SapoLog.hotkey.info("Recording toggle route=start count=\(toggleCount, privacy: .public)")
            startRecording()
        } else {
            SapoLog.hotkey.info("Recording toggle route=ignored count=\(toggleCount, privacy: .public)")
            return
        }
    }

    private func canStartRecordingFromHotkey() -> Bool {
        if let activeTranscriptionSessionID {
            SapoLog.hotkey.info(
                "Hotkey ignored while transcription session=\(activeTranscriptionSessionID, privacy: .public) is active"
            )
            return false
        }

        if appState.isBusyProcessing {
            SapoLog.hotkey.info("Hotkey ignored while app is processing or polishing")
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStartHotkeyTime
        guard elapsed >= Self.startHotkeyDebounce else {
            let elapsedMs = Int(elapsed * 1000)
            SapoLog.hotkey.info("Hotkey ignored by start debounce elapsed=\(elapsedMs, privacy: .public)ms")
            return false
        }

        return true
    }

    /// Toggle de pausa/resume (llamado por el botón del overlay)
    func togglePause() {
        if deepgramFluxTranscriber.isStreaming {
            if deepgramFluxTranscriber.isPaused {
                do {
                    try deepgramFluxTranscriber.resumeRecording()
                    overlayManager.updateState(.recording(duration: deepgramFluxTranscriber.recordingDuration))
                } catch {
                    print("❌ [flux] failed to resume recording: \(error)")
                }
            } else {
                deepgramFluxTranscriber.pauseRecording()
                overlayManager.updateState(.paused(duration: deepgramFluxTranscriber.recordingDuration))
                overlayManager.updateAudioLevel(0)
            }
            return
        }

        guard audioRecorder.isRecording else { return }

        if audioRecorder.isPaused {
            // Resume
            do {
                try audioRecorder.resumeRecording()
                overlayManager.updateState(.recording(duration: audioRecorder.recordingDuration))
            } catch {
                print("❌ [capture] failed to resume recording: \(error)")
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
        let triggerTime = CFAbsoluteTimeGetCurrent()
        let engine = currentEngine
        let sessionID = nextRecordingSessionID()
        lastStartHotkeyTime = triggerTime
        activeRecordingSessionID = sessionID
        SapoLog.hotkey.info(
            "Recording trigger accepted engine=\(engine.rawValue, privacy: .public) session=\(sessionID, privacy: .public)"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-trigger-accepted",
            context: diagnosticContext(extra: "session=\(sessionID)"),
            force: true
        )
        let missingPermissions = PermissionService.shared.missingRecordingPermissions(for: engine)

        guard missingPermissions.isEmpty else {
            activeRecordingSessionID = nil
            SapoLog.recording.warning("Recording blocked by missing permissions")
            PermissionService.shared.showRequirementsWindow(force: true)
            return
        }

        // Verificar que el motor actual tiene modelo cargado
        let isReady = isEngineReady(engine)

        guard isReady else {
            activeRecordingSessionID = nil
            appState = .noModel
            SapoLog.recording.warning("Recording blocked because engine is not ready")
            return
        }

        // Guardar la app activa para volver a ella despues de pegar
        PasteManager.savePreviousApp()

        // Mostrar overlay PRIMERO para feedback visual inmediato
        appState = .recording

        overlayManager.updateState(.recording(duration: 0))
        let uiReadyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
        SapoLog.recording.info("Recording UI ready in \(uiReadyMs, privacy: .public)ms")
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-ui-ready",
            context: diagnosticContext(extra: "session=\(sessionID) uiReadyMs=\(uiReadyMs)")
        )

        let mic = selectedMicrophone
        let playSound = playSoundEnabled
        isStartPending = true
        if isDeepgramFluxLiveSelected {
            if playSound {
                SoundManager.shared.play(.startRecording)
            }
            SapoLog.flux.info("Flux UI feedback emitted before input startup")
            startFluxRecordingSession(
                sessionID: sessionID,
                microphone: mic,
                playSound: false,
                triggerTime: triggerTime
            )
        } else {
            startRecordingSession(
                sessionID: sessionID,
                engine: engine,
                microphone: mic,
                playSound: playSound,
                triggerTime: triggerTime
            )
        }
    }

    private func cancelPendingRecordingStart() {
        guard isStartPending else { return }

        audioRecorder.cancelPendingSetup()
        deepgramFluxTranscriber.cancel()
        startRecordingTask?.cancel()
        startRecordingTask = nil
        isStartPending = false
        activeRecordingSessionID = nil
        overlayManager.updateAudioLevel(0)
        overlayManager.updateState(.hidden)
        restoreMicMonitorAfterRecordingIfNeeded()
        AutoDuckingManager.shared.restore()
        checkInitialState()
    }

    private func nextRecordingSessionID() -> UInt64 {
        recordingSessionCounter &+= 1
        return recordingSessionCounter
    }

    private func diagnosticContext(extra: String = "") -> String {
        let recordingSession = activeRecordingSessionID.map(String.init) ?? "none"
        let transcriptionSession = activeTranscriptionSessionID.map(String.init) ?? "none"
        let suffix = extra.isEmpty ? "" : " \(extra)"

        return
            "state=\(appState.diagnosticName) engine=\(currentEngine.rawValue) deepgramMode=\(currentDeepgramMode.rawValue) startPending=\(isStartPending) stopPending=\(isStopPending) audioRecording=\(audioRecorder.isRecording) fluxStreaming=\(deepgramFluxTranscriber.isStreaming) audioPaused=\(audioRecorder.isPaused) fluxPaused=\(deepgramFluxTranscriber.isPaused) duration=\(Int(recordingDuration)) recordingSession=\(recordingSession) transcriptionSession=\(transcriptionSession) mic=\(selectedMicrophone)\(suffix)"
    }

    private func handleStaleTranscriptionCompletion(audioURL: URL, sessionID: UInt64) {
        SapoLog.recording.warning(
            "Ignoring stale transcription completion session=\(sessionID, privacy: .public)"
        )
        audioRecorder.deleteRecording(at: audioURL)
    }

    private func requestStopRecordingAndTranscribe() {
        guard !isStopPending else {
            SapoLog.hotkey.info("Hotkey ignored because stop is already pending")
            return
        }
        isStopPending = true

        let tailPadding = Self.stopTailPadding
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-stop-requested",
            context: diagnosticContext(extra: "tailPaddingMs=\(Int(tailPadding * 1000))"),
            force: true
        )

        Task {
            try? await Task.sleep(nanoseconds: UInt64(tailPadding * 1_000_000_000))
            await MainActor.run {
                self.stopRecordingAndTranscribe()
            }
        }
    }

    private func requestStopFluxRecordingAndTranscribe() {
        guard !isStopPending else {
            SapoLog.hotkey.info("Hotkey ignored because Flux stop is already pending")
            return
        }
        isStopPending = true

        let tailPadding = Self.stopTailPadding
        let stopRequestTime = CFAbsoluteTimeGetCurrent()
        SapoLog.flux.info("Flux stop hotkey accepted tailPadding=\(Int(tailPadding * 1000), privacy: .public)ms")
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "flux-stop-requested",
            context: diagnosticContext(extra: "tailPaddingMs=\(Int(tailPadding * 1000))"),
            force: true
        )

        Task {
            try? await Task.sleep(nanoseconds: UInt64(tailPadding * 1_000_000_000))
            await MainActor.run {
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - stopRequestTime) * 1000)
                SapoLog.flux.info("Flux stop tail elapsed=\(elapsed, privacy: .public)ms")
                self.stopFluxRecordingAndTranscribe()
            }
        }
    }

    private func stopFluxRecordingAndTranscribe() {
        isStopPending = false
        defer { restoreMicMonitorAfterRecordingIfNeeded() }
        autoStopTimer?.invalidate()
        autoStopTimer = nil

        if playSoundEnabled {
            SoundManager.shared.play(.stopRecording)
        }

        let engine = TranscriptionEngine.deepgram
        let engineName = currentDeepgramMode.historyName
        let sessionID = activeRecordingSessionID ?? nextRecordingSessionID()
        activeRecordingSessionID = nil
        activeTranscriptionSessionID = sessionID
        appState = .processing
        overlayManager.updateState(.transcribing)
        SapoLog.flux.info("Flux overlay switched to transcribing session=\(sessionID, privacy: .public)")

        Task { @MainActor in
            do {
                let transcriptionStartedAt = CFAbsoluteTimeGetCurrent()
                let result = try await deepgramFluxTranscriber.stop()
                let transcriptionElapsed = Int((CFAbsoluteTimeGetCurrent() - transcriptionStartedAt) * 1000)
                SapoLog.flux.info(
                    "Flux stop/transcribe completed elapsed=\(transcriptionElapsed, privacy: .public)ms characters=\(result.transcript.count, privacy: .public)"
                )
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "flux-transcription-completed",
                    context: self.diagnosticContext(
                        extra:
                            "session=\(sessionID) elapsedMs=\(transcriptionElapsed) characters=\(result.transcript.count)"
                    ),
                    force: true
                )
                guard self.activeTranscriptionSessionID == sessionID else {
                    self.handleStaleTranscriptionCompletion(audioURL: result.audioURL, sessionID: sessionID)
                    return
                }

                let aiResult = await postProcessTranscript(result.transcript, source: "flux")
                guard self.activeTranscriptionSessionID == sessionID else {
                    self.handleStaleTranscriptionCompletion(audioURL: result.audioURL, sessionID: sessionID)
                    return
                }

                lastTranscription = aiResult.finalText
                PasteManager.copyToClipboard(aiResult.finalText)
                overlayManager.showCompleted(text: aiResult.finalText, autoDismissAfter: 2.0)

                if autoPasteEnabled {
                    PasteManager.simulatePaste()
                }

                appState = .idle
                activeTranscriptionSessionID = nil
                if playSoundEnabled {
                    SoundManager.shared.play(.success)
                }

                let persistedEntry = persistHistoryEntry(
                    from: result.audioURL,
                    engine: engine,
                    engineName: engineName,
                    language: result.language,
                    duration: result.duration,
                    aiResult: aiResult,
                    status: "completed"
                )
                cleanupSourceAudioIfSafe(sourceURL: result.audioURL, persistedEntry: persistedEntry)
                lastFailedAudioURL = nil
                lastFailedHistoryId = nil

            } catch {
                let captureResult = deepgramFluxTranscriber.lastCaptureResult
                if let captureResult, self.activeTranscriptionSessionID != sessionID {
                    self.handleStaleTranscriptionCompletion(audioURL: captureResult.audioURL, sessionID: sessionID)
                    return
                }

                appState = .error(error.localizedDescription)
                activeTranscriptionSessionID = nil
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "flux-transcription-failed",
                    context: self.diagnosticContext(extra: "session=\(sessionID) error=\(error.localizedDescription)"),
                    force: true
                )
                overlayManager.showError(message: error.localizedDescription)
                if playSoundEnabled {
                    SoundManager.shared.play(.error)
                }

                if let captureResult {
                    let persistedEntry = persistHistoryEntry(
                        from: captureResult.audioURL,
                        engine: engine,
                        engineName: engineName,
                        language: "auto",
                        duration: captureResult.duration,
                        aiResult: nil,
                        status: "failed"
                    )
                    lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
                    lastFailedAudioURL = persistedEntry.audioURL ?? captureResult.audioURL
                    cleanupSourceAudioIfSafe(sourceURL: captureResult.audioURL, persistedEntry: persistedEntry)
                }
                print("❌ [flux] \(error)")
            }
        }
    }

    /// Detiene la grabacion y transcribe
    private func stopRecordingAndTranscribe() {
        isStopPending = false
        defer { restoreMicMonitorAfterRecordingIfNeeded() }
        // Detener timers
        autoStopTimer?.invalidate()
        autoStopTimer = nil

        if playSoundEnabled {
            SoundManager.shared.play(.stopRecording)
        }

        let engine = currentEngine
        let language = selectedLanguage
        let duration = recordingDuration
        let sessionID = activeRecordingSessionID ?? nextRecordingSessionID()
        activeRecordingSessionID = nil
        activeTranscriptionSessionID = sessionID

        // All engines: stop recording, get audio file, transcribe
        guard let audioURL = audioRecorder.stopRecording() else {
            activeTranscriptionSessionID = nil
            appState = .error("error.no_audio".localized)
            overlayManager.showError(message: "error.no_audio".localized)
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            return
        }

        if let diagnostics = audioRecorder.lastCaptureDiagnostics, !diagnostics.receivedInput {
            print(
                "⚠️ [capture] dropping empty recording after device switch "
                    + "(\(diagnostics.fileSizeBytes) bytes, input: \(diagnostics.selectedDeviceUID))"
            )
            audioRecorder.deleteRecording(at: audioURL)
            activeTranscriptionSessionID = nil
            appState = .error("error.no_audio".localized)
            overlayManager.showError(message: "error.no_audio".localized)
            if playSoundEnabled {
                SoundManager.shared.play(.error)
            }
            return
        }

        appState = .processing

        // Actualizar overlay a transcribing
        overlayManager.updateState(.transcribing)

        Task { @MainActor in
            do {
                let transcription = try await transcribeAudio(at: audioURL, using: engine, language: language)
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "transcription-completed",
                    context: self.diagnosticContext(
                        extra: "session=\(sessionID) engine=\(engine.rawValue) characters=\(transcription.count)"
                    ),
                    force: true
                )
                guard self.activeTranscriptionSessionID == sessionID else {
                    self.handleStaleTranscriptionCompletion(audioURL: audioURL, sessionID: sessionID)
                    return
                }

                let aiResult = await postProcessTranscript(transcription, source: engine.rawValue)
                guard self.activeTranscriptionSessionID == sessionID else {
                    self.handleStaleTranscriptionCompletion(audioURL: audioURL, sessionID: sessionID)
                    return
                }

                lastTranscription = aiResult.finalText
                PasteManager.copyToClipboard(aiResult.finalText)
                overlayManager.showCompleted(text: aiResult.finalText, autoDismissAfter: 2.0)

                if autoPasteEnabled {
                    PasteManager.simulatePaste()
                }

                appState = .idle
                activeTranscriptionSessionID = nil
                if playSoundEnabled {
                    SoundManager.shared.play(.success)
                }

                let persistedEntry = persistHistoryEntry(
                    from: audioURL,
                    engine: engine,
                    language: language,
                    duration: duration,
                    aiResult: aiResult,
                    status: "completed"
                )
                cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
                lastFailedAudioURL = nil
                lastFailedHistoryId = nil

            } catch {
                guard self.activeTranscriptionSessionID == sessionID else {
                    self.handleStaleTranscriptionCompletion(audioURL: audioURL, sessionID: sessionID)
                    return
                }
                appState = .error(error.localizedDescription)
                activeTranscriptionSessionID = nil
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "transcription-failed",
                    context: self.diagnosticContext(
                        extra: "session=\(sessionID) engine=\(engine.rawValue) error=\(error.localizedDescription)"
                    ),
                    force: true
                )
                overlayManager.showError(message: error.localizedDescription)
                if playSoundEnabled {
                    SoundManager.shared.play(.error)
                }

                let persistedEntry = persistHistoryEntry(
                    from: audioURL,
                    engine: engine,
                    language: language,
                    duration: duration,
                    aiResult: nil,
                    status: "failed"
                )
                lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
                lastFailedAudioURL = persistedEntry.audioURL ?? audioURL
                cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
                print("❌ [transcription] \(engine.displayName): \(error)")
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
            return  // No limit for Apple/WhisperKit
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
        guard let audioURL = lastFailedAudioURL else {
            guard canStartRecordingFromHotkey() else { return }
            startRecording()
            return
        }

        appState = .processing
        overlayManager.updateState(.transcribing)

        let engine = currentEngine
        let language = selectedLanguage

        Task {
            do {
                let transcription = try await transcribeAudio(at: audioURL, using: engine, language: language)
                let aiResult = await postProcessTranscript(transcription, source: "retry")

                lastTranscription = aiResult.finalText
                PasteManager.copyToClipboard(aiResult.finalText)
                overlayManager.showCompleted(text: aiResult.finalText, autoDismissAfter: 2.0)

                if autoPasteEnabled {
                    PasteManager.simulatePaste()
                }

                appState = .idle
                if playSoundEnabled { SoundManager.shared.play(.success) }

                // Update history entry
                if let historyId = lastFailedHistoryId {
                    historyManager.updateAIProcessing(
                        id: historyId,
                        finalText: aiResult.finalText,
                        rawText: aiResult.rawText,
                        aiStatus: aiResult.status,
                        aiModel: aiResult.model,
                        aiMode: aiResult.mode,
                        aiError: aiResult.error
                    )
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

    func retranscribeHistoryEntry(_ entry: HistoryEntry, using engine: TranscriptionEngine) async -> HistoryRetranscriptionResult {
        guard let audioPath = entry.audioPath, FileManager.default.fileExists(atPath: audioPath) else {
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                errorMessage: "history.audio_missing_error".localized
            )
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        do {
            let transcription = try await transcribeAudio(at: audioURL, using: engine, language: entry.language)
            let aiResult = await postProcessTranscript(transcription, source: "history-retranscribe")
            let persistedEntry = persistHistoryEntry(
                from: audioURL,
                engine: engine,
                language: entry.language,
                duration: entry.duration,
                aiResult: aiResult,
                status: "completed"
            )

            return HistoryRetranscriptionResult(
                entryId: persistedEntry.id > 0 ? persistedEntry.id : entry.id,
                errorMessage: nil
            )
        } catch {
            let persistedEntry = persistHistoryEntry(
                from: audioURL,
                engine: engine,
                language: entry.language,
                duration: entry.duration,
                aiResult: nil,
                status: "failed"
            )

            return HistoryRetranscriptionResult(
                entryId: persistedEntry.id > 0 ? persistedEntry.id : entry.id,
                errorMessage: error.localizedDescription
            )
        }
    }

    func polishHistoryEntry(_ entry: HistoryEntry) async -> HistoryRetranscriptionResult {
        let sourceText = (entry.hasRawTranscript ? entry.rawText : entry.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sourceText.isEmpty, entry.status == "completed" else {
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                errorMessage: "history.ai_polish_missing_text".localized
            )
        }

        let aiResult = await transcriptPostProcessor.process(rawText: sourceText, force: true)
        logAIResult(aiResult, source: "history-polish")
        historyManager.updateAIProcessing(
            id: entry.id,
            finalText: aiResult.finalText,
            rawText: aiResult.rawText,
            aiStatus: aiResult.status,
            aiModel: aiResult.model,
            aiMode: aiResult.mode,
            aiError: aiResult.error
        )

        return HistoryRetranscriptionResult(
            entryId: entry.id,
            errorMessage: aiResult.status == .failed ? aiResult.error : nil
        )
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.registerHotkey { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.toggleRecording()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.toggleRecording()
                    }
                }
            }
        }
    }

    private func startRecordingSession(
        sessionID: UInt64,
        engine: TranscriptionEngine,
        microphone: String,
        playSound: Bool,
        triggerTime: CFAbsoluteTime
    ) {
        if isStartPending {
            audioRecorder.cancelPendingSetup()
        }
        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didSuspendMonitor = self.suspendMicMonitorForRecordingIfNeeded()
            var recorderDidStart = false

            defer {
                self.isStartPending = false
                self.startRecordingTask = nil
                if didSuspendMonitor && !recorderDidStart {
                    self.restoreMicMonitorAfterRecordingIfNeeded()
                }
            }

            do {
                try await self.startRecorderWithRecovery(microphone: microphone)
                recorderDidStart = true
                let readyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
                SapoLog.recording.info("Recording input ready in \(readyMs, privacy: .public)ms")
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "recording-input-ready",
                    context: self.diagnosticContext(extra: "session=\(sessionID) readyMs=\(readyMs)"),
                    force: true
                )
                self.startAutoStopTimer(for: engine)
                if playSound {
                    SoundManager.shared.play(.startRecording)
                }
            } catch {
                if error is CancellationError {
                    return
                }
                guard self.activeRecordingSessionID == sessionID else {
                    SapoLog.recording.warning(
                        "Ignoring stale recording start failure session=\(sessionID, privacy: .public)"
                    )
                    return
                }
                self.activeRecordingSessionID = nil
                self.appState = .error(error.localizedDescription)
                self.overlayManager.showError(message: error.localizedDescription)
                AutoDuckingManager.shared.restore()
                if playSound && !self.isRecoverableInputStartError(error) {
                    SoundManager.shared.play(.error)
                }
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "recording-input-failed",
                    context: self.diagnosticContext(
                        extra: "session=\(sessionID) error=\(error.localizedDescription)"
                    ),
                    force: true
                )
                SapoLog.recording.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                print("❌ [capture] failed to start recording: \(error)")
            }
        }
    }

    private func startFluxRecordingSession(
        sessionID: UInt64,
        microphone: String,
        playSound: Bool,
        triggerTime: CFAbsoluteTime
    ) {
        deepgramFluxTranscriber.cancel()
        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didSuspendMonitor = self.suspendMicMonitorForRecordingIfNeeded()
            var recorderDidStart = false

            defer {
                self.isStartPending = false
                self.startRecordingTask = nil
                if didSuspendMonitor && !recorderDidStart {
                    self.restoreMicMonitorAfterRecordingIfNeeded()
                }
            }

            do {
                try await self.deepgramFluxTranscriber.start(microphone: microphone)
                recorderDidStart = true
                let readyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
                SapoLog.recording.info("Flux input ready in \(readyMs, privacy: .public)ms")
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "flux-input-ready",
                    context: self.diagnosticContext(extra: "session=\(sessionID) readyMs=\(readyMs)"),
                    force: true
                )
                if playSound {
                    SoundManager.shared.play(.startRecording)
                }
            } catch {
                if error is CancellationError {
                    return
                }
                guard self.activeRecordingSessionID == sessionID else {
                    SapoLog.recording.warning(
                        "Ignoring stale Flux start failure session=\(sessionID, privacy: .public)"
                    )
                    return
                }
                self.activeRecordingSessionID = nil
                self.appState = .error(error.localizedDescription)
                self.overlayManager.showError(message: error.localizedDescription)
                AutoDuckingManager.shared.restore()
                if playSound && !self.isRecoverableInputStartError(error) {
                    SoundManager.shared.play(.error)
                }
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "flux-input-failed",
                    context: self.diagnosticContext(
                        extra: "session=\(sessionID) error=\(error.localizedDescription)"
                    ),
                    force: true
                )
                SapoLog.recording.error("Flux failed to start: \(error.localizedDescription, privacy: .public)")
                print("❌ [flux] failed to start: \(error)")
            }
        }
    }

    private func startRecorderWithRecovery(microphone: String) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + Self.startRetryBudget
        var lastFailure: Error = RecordingError.noInputAfterDeviceSwitch

        for attempt in 1...3 {
            guard !Task.isCancelled else { throw CancellationError() }

            do {
                let didStart = try await attemptRecorderStart(
                    microphone: microphone,
                    attempt: attempt,
                    minimumDelay: attempt == 1 ? 0 : Self.startRetryBackoffs[attempt - 2]
                )
                if didStart {
                    if attempt > 1 {
                        print("✅ [capture] recovered on retry after route transition")
                    }
                    return
                }
                lastFailure = RecordingError.noInputAfterDeviceSwitch
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastFailure = error
            }

            audioRecorder.discardRecording()

            guard attempt < 3 else { break }

            let routeTransitionActive = AudioDeviceManager.shared.captureRouteSettleDelay() > 0
            let classification = classifyRecordingStartFailure(lastFailure, routeTransitionActive: routeTransitionActive)
            guard classification.isTransient else {
                throw lastFailure
            }

            let remainingBudget = deadline - CFAbsoluteTimeGetCurrent()
            guard remainingBudget > 0 else { break }

            let retryDelay = min(
                remainingBudget,
                max(Self.startRetryBackoffs[attempt - 1], AudioDeviceManager.shared.captureRouteSettleDelay())
            )

            print(
                "🎙️ [capture] transient start failure (\(classification.reason)), "
                    + "retrying \(attempt + 1)/3 after \(Int(retryDelay * 1000))ms"
            )
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }

        throw lastFailure
    }

    private func attemptRecorderStart(
        microphone: String,
        attempt: Int,
        minimumDelay: TimeInterval
    ) async throws -> Bool {
        audioRecorder.selectedDeviceUID = microphone
        let settleDelay = max(minimumDelay, audioRecorder.prepareInputDeviceForRecording())
        if settleDelay > 0 {
            let settleMs = Int(settleDelay * 1000)
            SapoLog.recording.info("Delaying recorder start for route settle \(settleMs, privacy: .public)ms")
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }

        guard !Task.isCancelled else { return false }

        try await audioRecorder.startRecording()
        let receivedInput = await audioRecorder.waitForFirstInputBuffer(timeout: Self.firstInputBufferTimeout)
        if receivedInput {
            return true
        }

        let diagnostics = audioRecorder.currentCaptureDiagnostics()
        let inputDescription = diagnostics.selectedDeviceUID == "default" ? "system-default" : diagnostics.selectedDeviceUID
        print(
            "⚠️ [capture] attempt \(attempt) received no input buffer within " + "\(Int(Self.firstInputBufferTimeout * 1000))ms "
                + "(bytes: \(diagnostics.fileSizeBytes), input: \(inputDescription))"
        )
        return false
    }

    private func suspendMicMonitorForRecordingIfNeeded() -> Bool {
        let shouldResume = AudioLevelMonitor.shared.suspendForRecorder()
        if shouldResume {
            shouldResumeMicMonitorAfterRecording = true
        }
        return shouldResume
    }

    private func isRecoverableInputStartError(_ error: Error) -> Bool {
        guard let recordingError = error as? RecordingError else { return false }

        switch recordingError {
        case .noInputAfterDeviceSwitch, .invalidFormat:
            return true
        case .engineCreationFailed,
            .fileCreationFailed,
            .converterCreationFailed,
            .deviceSelectionFailed,
            .permissionDenied:
            return false
        }
    }

    private func restoreMicMonitorAfterRecordingIfNeeded() {
        guard shouldResumeMicMonitorAfterRecording else { return }
        shouldResumeMicMonitorAfterRecording = false
        AudioLevelMonitor.shared.resumeAfterRecorderIfNeeded()
    }

    private func transcribeAudio(at audioURL: URL, using engine: TranscriptionEngine, language: String) async throws -> String {
        switch engine {
        case .appleOnline:
            guard PermissionService.shared.isGranted(.speechRecognition) else {
                throw TranscriberError.permissionDenied
            }
            return try await transcriber.transcribe(audioURL: audioURL, language: language)
        case .whisperLocal:
            return try await whisperKitTranscriber.transcribe(audioURL: audioURL, language: language)
        case .googleCloud:
            return try await googleCloudTranscriber.transcribe(audioURL: audioURL, language: language)
        case .deepgram:
            return try await deepgramTranscriber.transcribe(audioURL: audioURL, language: language)
        }
    }

    private func postProcessTranscript(_ rawText: String, source: String) async -> TranscriptAIResult {
        let willAttemptPolish = transcriptPostProcessor.willAttemptPolish(rawText: rawText)
        if willAttemptPolish {
            appState = .polishing
            overlayManager.updateState(.polishing)
            SapoLog.ai.info(
                "AI polish started source=\(source, privacy: .public) rawChars=\(rawText.count, privacy: .public)"
            )
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "ai-polish-start",
                context: diagnosticContext(extra: "source=\(source) rawChars=\(rawText.count)"),
                force: true
            )
        }

        let result = await transcriptPostProcessor.process(rawText: rawText)
        logAIResult(result, source: source)
        if willAttemptPolish {
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "ai-polish-finished",
                context: diagnosticContext(
                    extra:
                        "source=\(source) status=\(result.status.rawValue) elapsedMs=\(result.elapsedMs) rawChars=\(result.rawText.count) finalChars=\(result.finalText.count)"
                ),
                force: true
            )
        }
        return result
    }

    private func logAIResult(_ result: TranscriptAIResult, source: String) {
        let mode = result.mode?.rawValue ?? "none"
        let model = result.model ?? "none"
        let fallbackReason = result.error ?? "none"
        SapoLog.ai.info(
            "AI polish source=\(source, privacy: .public) status=\(result.status.rawValue, privacy: .public) mode=\(mode, privacy: .public) model=\(model, privacy: .public) elapsed=\(result.elapsedMs, privacy: .public)ms rawChars=\(result.rawText.count, privacy: .public) finalChars=\(result.finalText.count, privacy: .public) fallback=\(fallbackReason, privacy: .public)"
        )
    }

    private func persistHistoryEntry(
        from sourceURL: URL,
        engine: TranscriptionEngine,
        engineName: String? = nil,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult?,
        status: String
    ) -> PersistedHistoryEntry {
        let savedPath = historyManager.saveAudioFile(from: sourceURL)
        let fallbackPath = FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL.path : nil
        let audioPath = savedPath ?? fallbackPath
        let text = aiResult?.finalText ?? ""
        let historyID = historyManager.save(
            engine: engineName ?? engine.displayName,
            language: language,
            duration: duration,
            text: text,
            rawText: aiResult?.rawText ?? text,
            audioPath: audioPath,
            status: status,
            aiStatus: aiResult?.status.rawValue ?? TranscriptAIStatus.none.rawValue,
            aiModel: aiResult?.model,
            aiMode: aiResult?.mode?.rawValue,
            aiError: aiResult?.error
        )

        return PersistedHistoryEntry(
            id: historyID,
            audioURL: audioPath.map { URL(fileURLWithPath: $0) },
            copiedAudioToHistory: savedPath != nil
        )
    }

    private func cleanupSourceAudioIfSafe(sourceURL: URL, persistedEntry: PersistedHistoryEntry) {
        guard persistedEntry.copiedAudioToHistory else {
            SapoLog.recording.warning(
                "Keeping source audio because history copy was unavailable path=\(sourceURL.path, privacy: .private)"
            )
            return
        }

        audioRecorder.deleteRecording(at: sourceURL)
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
        isAnyRecorderActive ? "menu.stop_recording".localized : "menu.start_recording".localized
    }

    /// Si el boton de grabar esta habilitado
    var canRecord: Bool {
        guard activeTranscriptionSessionID == nil, !appState.isBusyProcessing else {
            return false
        }

        switch currentEngine {
        case .appleOnline:
            return !transcriber.isTranscribing
        case .whisperLocal:
            return whisperKitTranscriber.isModelLoaded && !whisperKitTranscriber.isTranscribing
        case .googleCloud:
            return googleCloudTranscriber.isConfigured && !googleCloudTranscriber.isTranscribing
        case .deepgram:
            return deepgramTranscriber.isConfigured && !deepgramTranscriber.isTranscribing && !deepgramFluxTranscriber.isStreaming
                && !deepgramFluxTranscriber.isStopping
        }
    }

    /// Formatea la duración de grabación
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
