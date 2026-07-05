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
        /// Fatal failure — surfaced in the "action failed" alert.
        let errorMessage: String?
        /// Non-fatal outcome (polish discarded by the fidelity guard, or no
        /// usable provider) — surfaced in a neutral notice, never as an error.
        let noticeMessage: String?

        init(entryId: Int64, errorMessage: String? = nil, noticeMessage: String? = nil) {
            self.entryId = entryId
            self.errorMessage = errorMessage
            self.noticeMessage = noticeMessage
        }
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

    /// 10 Hz dictation ticker kept OFF the ObservableObject: as @Published it
    /// re-rendered EVERY view observing the ViewModel (Settings tabs, menu
    /// bar, onboarding) on each tick while recording. Timer views subscribe
    /// to the subject directly; ViewModel logic reads the plain value.
    let recordingDurationSubject = CurrentValueSubject<TimeInterval, Never>(0)
    var recordingDuration: TimeInterval {
        get { recordingDurationSubject.value }
        set { recordingDurationSubject.send(newValue) }
    }

    // Motor de transcripcion — passthroughs to the @Observable transcriber.
    // No more @Published mirrors: SwiftUI tracks the transcriber property a
    // view actually reads, so 60 Hz load-progress ticks stop invalidating
    // every ViewModel observer.
    var isLoadingWhisperKit: Bool { whisperKitTranscriber.isLoading }
    var whisperKitLoadingProgress: Double { whisperKitTranscriber.loadingProgress }
    var whisperKitLoadingMessage: String { whisperKitTranscriber.loadingMessage }
    /// Combine bridge for AppKit-side consumers (MenuBarStatusController)
    /// that need a publisher now that the transcriber has none.
    let isLoadingWhisperKitSubject = CurrentValueSubject<Bool, Never>(false)

    // MARK: - AppStorage Properties

    /// New installs auto-detect the spoken language; every current engine
    /// (WhisperKit, Local AI Server, Deepgram, ElevenLabs) supports detection natively.
    @AppStorage(Constants.StorageKeys.language) var selectedLanguage = "auto"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyTriggerKind) var hotkeyTriggerKind: String = Constants.Hotkey.defaultTriggerKind
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.hotkeyDoubleTapModifier) var hotkeyDoubleTapModifier: Int = Int(
        Constants.Hotkey.defaultDoubleTapModifier
    )
    @AppStorage(Constants.StorageKeys.playSound) var playSoundEnabled = true
    /// Same key the Settings toggle writes; before this the menu toggle drove
    /// a non-persisted @Published and the Settings toggle changed nothing.
    @AppStorage(Constants.StorageKeys.autoPaste) var autoPasteEnabled = true
    @AppStorage(Constants.StorageKeys.transcriptionEngine) var selectedEngine: String = TranscriptionEngine.whisperLocal.rawValue
    // Default: the official large-v3 turbo — a whole WER class above `small`
    // for Spanish + technical terms at low latency on Apple Silicon.
    @AppStorage(Constants.StorageKeys.whisperKitModel) var selectedWhisperModel: String =
        WhisperKitModel.largev3V20240930.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) var selectedDeepgramMode: String = DeepgramTranscriptionMode.nova3.rawValue
    @AppStorage(Constants.StorageKeys.elevenLabsTranscriptionMode) var selectedElevenLabsMode: String =
        ElevenLabsTranscriptionMode.defaultMode.rawValue
    @AppStorage(Constants.StorageKeys.localAIServerModel) var selectedLocalAIServerModel: String =
        LocalAIServerConfiguration.defaultModel

    // MARK: - Managers

    let audioRecorder = AudioCaptureEngine(mode: .batch)
    let whisperKitTranscriber = WhisperKitTranscriber()
    let hotkeyManager = HotkeyManager.shared
    let overlayManager = OverlayWindowManager.shared
    let deepgramTranscriber = DeepgramBatchTranscriber()
    let deepgramFluxTranscriber = DeepgramFluxLiveTranscriber()
    let elevenLabsTranscriber = ElevenLabsScribeTranscriber()
    let elevenLabsRealtimeTranscriber = ElevenLabsScribeRealtimeTranscriber()
    let localAIServerTranscriber = LocalAIServerTranscriber()
    private let historyManager = TranscriptionHistoryManager.shared
    private let transcriptPostProcessor = TranscriptPostProcessor()

    // Retry support
    @Published var lastFailedAudioURL: URL?
    private var lastFailedHistoryId: Int64?

    // Overlay re-polish support
    /// Raw transcript + duration of the last live dictation, kept so the
    /// completed pill can re-polish the same text (e.g. after toggling the
    /// translation chip).
    private var lastDictationRawText: String?
    private var lastDictationDuration: TimeInterval?
    /// History row of the last completed dictation (arrives async from the
    /// background persistence task); lets a re-polish update the row in place.
    private var lastCompletedHistoryId: Int64?
    /// Invalidates a stale persistence callback racing a newer dictation.
    private var dictationGeneration: UInt64 = 0
    private var isRepolishInFlight = false

    // Reentrancy guard for retryTranscription: a second Retry (double click /
    // repeated hotkey) before the in-flight retry resolves would transcribe and
    // paste the same audio twice. Set before the Task, cleared in its defer.
    private var isRetryInFlight = false

    private static let stopTailPadding: TimeInterval = 0.12
    private static let firstInputBufferTimeout: TimeInterval = 0.8
    private static let startRetryBudget: TimeInterval = 1.0
    /// Bluetooth inputs renegotiate the link when the mic opens (AirPods
    /// switch A2DP→HFP, 1–3 s of dead air). The default timeouts declared the
    /// capture failed while the handshake was still in flight, so BT inputs
    /// get a wider first-buffer window and retry budget.
    private static let bluetoothFirstInputBufferTimeout: TimeInterval = 2.5
    private static let bluetoothStartRetryBudget: TimeInterval = 5.0
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
    /// A5: single owner of mic exclusivity (monitor suspend/resume, overlap assert).
    private let captureCoordinator = AudioCaptureCoordinator.shared
    /// C1: shared transcribe→polish→paste→persist flow for the three stop paths.
    private lazy var transcriptionPipeline = TranscriptionPipeline(host: self)

    // No-speech fast path: track the session peak from the overlay level
    // stream. The threshold is deliberately conservative (~−55 dBFS in the
    // normalized 0...1 scale) so quiet speakers are never misclassified.
    private var sessionPeakAudioLevel: Float = 0
    private var sessionLevelTrackingStartedAt: CFAbsoluteTime = 0
    private static let noSpeechPeakLevelThreshold: Float = 0.085
    private static let noSpeechHintDelay: TimeInterval = 3.0

    var sessionLooksSilent: Bool {
        sessionPeakAudioLevel < Self.noSpeechPeakLevelThreshold
    }

    // MARK: - Resumable dictation (continue-previous merge)

    /// A recently cancelled or crash-recovered take the user may prepend to
    /// the next recording ("continuar dictado anterior").
    struct ResumableDictation {
        let historyId: Int64
        let audioURL: URL
        let duration: TimeInterval
        let capturedAt: Date
    }

    private var resumableDictation: ResumableDictation?
    /// The user opted into the merge via the recording pill chip.
    private var resumeMergeRequested = false
    /// Offers older than this are stale — a new dictation is a new thought.
    private static let resumableDictationWindow: TimeInterval = 30 * 60

    /// The current offer, or nil when expired / audio gone.
    private var validResumableDictation: ResumableDictation? {
        guard let resumable = resumableDictation else { return nil }
        guard Date().timeIntervalSince(resumable.capturedAt) < Self.resumableDictationWindow,
            FileManager.default.fileExists(atPath: resumable.audioURL.path)
        else {
            resumableDictation = nil
            return nil
        }
        return resumable
    }

    /// Launch-time entry point: the orphan recovery adopted a crashed take.
    func offerResumableDictation(_ resumable: ResumableDictation) {
        resumableDictation = resumable
    }

    /// m:ss label for the resume chip.
    private static func formatResumeDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Computed Properties

    var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .whisperLocal
    }

    var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }

    var currentDeepgramMode: DeepgramTranscriptionMode {
        DeepgramTranscriptionMode(rawValue: selectedDeepgramMode) ?? .nova3
    }

    var currentElevenLabsMode: ElevenLabsTranscriptionMode {
        ElevenLabsTranscriptionMode(rawValue: selectedElevenLabsMode) ?? .defaultMode
    }

    private var isDeepgramFluxLiveSelected: Bool {
        currentEngine == .deepgram && currentDeepgramMode == .fluxLive
    }

    private var isElevenLabsRealtimeSelected: Bool {
        currentEngine == .elevenLabsScribe && currentElevenLabsMode == .scribeV2Realtime
    }

    private var isAnyRecorderActive: Bool {
        audioRecorder.isRecording || deepgramFluxTranscriber.isStreaming || elevenLabsRealtimeTranscriber.isStreaming
    }

    var isWhisperKitReady: Bool {
        whisperKitTranscriber.isModelLoaded
    }

    /// The concrete transcriber(s) backing one logical engine. Single source
    /// of truth for "which sessions make up this engine"; readiness/busy are
    /// derived from it uniformly, replacing the per-query `switch currentEngine`.
    func engineSessions(for engine: TranscriptionEngine) -> EngineSessions {
        switch engine {
        case .whisperLocal:
            return EngineSessions(readiness: whisperKitTranscriber, busy: [whisperKitTranscriber])
        case .localAIServer:
            return EngineSessions(readiness: localAIServerTranscriber, busy: [localAIServerTranscriber])
        case .deepgram:
            return EngineSessions(
                readiness: deepgramTranscriber,
                busy: [deepgramTranscriber, deepgramFluxTranscriber]
            )
        case .elevenLabsScribe:
            return EngineSessions(
                readiness: elevenLabsTranscriber,
                busy: [elevenLabsTranscriber, elevenLabsRealtimeTranscriber]
            )
        }
    }

    func isEngineReady(_ engine: TranscriptionEngine) -> Bool {
        engineSessions(for: engine).isReady
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

        // A8: the preflight engine must never warm the HAL while a capture
        // owns the input device. Evaluated on the main thread by the manager.
        // A5: the coordinator covers the begin→end window (wider than the
        // isRecording flags); the recorder flags stay as a backstop.
        AudioInputPreflightManager.shared.isCaptureActive = { [weak self] in
            MainActor.assumeIsolated {
                AudioCaptureCoordinator.shared.isCaptureActive || (self?.isAnyRecorderActive ?? false)
            }
        }

        // A2: a capture that dies mid-recording (device unplugged, recovery
        // failed) aborts cleanly: WAV preserved, failed row, clear error.
        // The recorder always delivers this callback on the main queue.
        audioRecorder.onCaptureInterrupted = { [weak self] reason in
            MainActor.assumeIsolated {
                self?.handleCaptureDeviceFailure(reason: reason)
            }
        }
        deepgramFluxTranscriber.onCaptureInterrupted = { [weak self] reason in
            self?.handleCaptureDeviceFailure(reason: reason)
        }
        elevenLabsRealtimeTranscriber.onCaptureInterrupted = { [weak self] reason in
            self?.handleCaptureDeviceFailure(reason: reason)
        }

        // Cargar modelo automaticamente si el motor es WhisperLocal
        if currentEngine == .whisperLocal {
            Task {
                await loadWhisperKitModel()
            }
        }

    }

    /// Configura callbacks del overlay (pause/resume/retry/chips)
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
        overlayManager.onQuickTranslationToggled = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.syncTranscriptionLanguageForTranslation()
            }
            SapoLog.ai.info("Quick translation toggled from overlay enabled=\(enabled, privacy: .public)")
        }
        overlayManager.onRepolishRequested = { [weak self] in
            Task { @MainActor in
                self?.repolishLastTranscription()
            }
        }
        overlayManager.onResumeToggled = { [weak self] isActive in
            guard let self else { return }
            self.resumeMergeRequested = isActive
            SapoLog.recording.info("Resume-previous merge toggled active=\(isActive, privacy: .public)")
        }
    }

    /// Mirrors the Settings behavior: engines never translate, so the moment
    /// translation becomes active the spoken language is unknown — reset the
    /// recognition hint to auto-detect.
    func syncTranscriptionLanguageForTranslation() {
        let defaults = UserDefaults.standard
        let value =
            defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue
        let outputLanguage = TranscriptPolishOutputLanguage(rawValue: value) ?? .sameAsInput
        let enabled = defaults.bool(forKey: Constants.StorageKeys.aiPolishEnabled)
        guard enabled, outputLanguage.requiresTranslation, selectedLanguage != "auto" else { return }
        selectedLanguage = "auto"
        SapoLog.settings.info(
            "Transcription language reset to auto reason=quick-translation target=\(outputLanguage.rawValue, privacy: .public)"
        )
    }

    /// Carga las configuraciones guardadas
    private func loadSavedSettings() {
        // Aplicar micrófono guardado
        audioRecorder.selectedDeviceUID = selectedMicrophone

        // Aplicar hotkey guardado
        hotkeyManager.currentTriggerKind = HotkeyTriggerKind(rawValue: hotkeyTriggerKind) ?? .keyCombination
        hotkeyManager.currentKeyCode = UInt32(hotkeyKeyCode)
        hotkeyManager.currentModifiers = UInt32(hotkeyModifiers)
        hotkeyManager.currentDoubleTapModifier = UInt32(hotkeyDoubleTapModifier)
    }

    private func setupBindings() {
        // Observar estado de grabacion
        audioRecorder.isRecordingPublisher
            .sink { [weak self] isRecording in
                if isRecording {
                    self?.appState = .recording
                }
            }
            .store(in: &cancellables)

        // Observar duracion de grabacion
        audioRecorder.recordingDurationPublisher
            .sink { [weak self] duration in
                guard self?.deepgramFluxTranscriber.isStreaming != true else { return }
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        // Streaming sessions share one binding set (state, duration, level,
        // overlay duration) parametrized by owning engine.
        bindStreamingSession(deepgramFluxTranscriber, engine: .deepgram)
        bindStreamingSession(elevenLabsRealtimeTranscriber, engine: .elevenLabsScribe)

        // Observar estado de transcripcion (WhisperKit) — callback hooks on
        // the @Observable transcriber replace the old Combine sinks.
        whisperKitTranscriber.onTranscribingChanged = { [weak self] isTranscribing in
            guard let self, !self.isReprocessingHistory else { return }
            if isTranscribing {
                self.appState = .processing
            }
        }

        // Observar carga de WhisperKit (estado propio + icono del Dock)
        whisperKitTranscriber.onLoadingChanged = { [weak self] isLoading in
            guard let self else { return }
            self.isLoadingWhisperKitSubject.send(isLoading)
            if self.currentEngine == .whisperLocal {
                DockIconManager.shared.updateIcon(for: self.appState, isModelLoading: isLoading)
            }
        }

        // Observar cuando el modelo esta listo (WhisperKit)
        whisperKitTranscriber.onModelLoadedChanged = { [weak self] isLoaded in
            guard let self else { return }
            guard self.currentEngine == .whisperLocal, isLoaded else { return }
            // An on-demand reload can finish mid-recording — only leave the
            // "no model" state so it never clobbers .recording/.processing/
            // .polishing (mirrors the guard in loadWhisperKitModel()).
            if case .noModel = self.appState {
                self.appState = .idle
            }
        }

        // Observar estado de transcripcion (ElevenLabs Scribe)
        elevenLabsTranscriber.$isTranscribing
            .sink { [weak self] isTranscribing in
                guard let self, !self.isReprocessingHistory else { return }
                if isTranscribing {
                    self.appState = .processing
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
                // Esc cancela el dictado solo mientras hay sesión activa
                self?.hotkeyManager.setCancelKeyActive(state == .recording) { [weak self] in
                    self?.cancelActiveDictation()
                }
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
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Observar nivel de audio del recorder para el overlay
        audioRecorder.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.overlayManager.updateAudioLevel(level)
                self?.registerSessionAudioLevel(level)
            }
            .store(in: &cancellables)

        // Update overlay duration during recording
        audioRecorder.recordingDurationPublisher
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

        // Observe device changes for visual notification
        AudioDeviceManager.shared.$deviceChangeAnnouncement
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] announcement in
                self?.overlayManager.showDeviceChange(announcement)
            }
            .store(in: &cancellables)
    }

    /// One binding set per streaming session: state, duration mirror, audio
    /// level, and overlay duration — the duration/level sinks only apply while
    /// the owning engine is the selected one (mirrors the historical guards).
    private func bindStreamingSession(_ session: any StreamingDictationSession, engine: TranscriptionEngine) {
        session.isStreamingPublisher
            .sink { [weak self] isStreaming in
                if isStreaming {
                    self?.appState = .recording
                }
            }
            .store(in: &cancellables)

        session.recordingDurationPublisher
            .sink { [weak self] duration in
                guard self?.currentEngine == engine else { return }
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        session.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard self?.currentEngine == engine else { return }
                self?.overlayManager.updateAudioLevel(level)
                self?.registerSessionAudioLevel(level)
            }
            .store(in: &cancellables)

        session.recordingDurationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self, self.currentEngine == engine else { return }
                switch self.overlayManager.state {
                case .recording:
                    self.overlayManager.updateRecordingDuration(duration)
                default:
                    break  // Don't update timer during pause
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Streaming engine contexts

    /// Per-engine wiring for one streaming dictation path. Built on demand so
    /// history names always reflect the current mode selection; every VM flow
    /// (start, stop, pause, abort) reads the SAME context instead of keeping a
    /// hand-written copy per engine.
    private struct StreamingEngineContext {
        let session: any StreamingDictationSession
        let owner: AudioCaptureCoordinator.CaptureOwner
        let engine: TranscriptionEngine
        /// History/perf label for rows and the perf timeline.
        let engineName: String
        /// `TranscriptionPipeline.Request` source tag.
        let source: String
        /// Snapshot-reason prefix, e.g. "flux" → "flux-stop-requested".
        let snapshotPrefix: String
        /// Human log label, e.g. "Flux" / "ElevenLabs realtime".
        let logLabel: String
        let logger: Logger
        /// Language recorded on a failed row when the stream dies.
        let failureLanguage: String
    }

    private var fluxContext: StreamingEngineContext {
        StreamingEngineContext(
            session: deepgramFluxTranscriber,
            owner: .fluxStreaming,
            engine: .deepgram,
            engineName: currentDeepgramMode.historyName,
            source: "flux",
            snapshotPrefix: "flux",
            logLabel: "Flux",
            logger: SapoLog.flux,
            failureLanguage: "auto"
        )
    }

    private var elevenLabsRealtimeContext: StreamingEngineContext {
        StreamingEngineContext(
            session: elevenLabsRealtimeTranscriber,
            owner: .elevenLabsStreaming,
            engine: .elevenLabsScribe,
            engineName: currentElevenLabsMode.historyName,
            source: "elevenlabs_realtime",
            snapshotPrefix: "elevenlabs-realtime",
            logLabel: "ElevenLabs realtime",
            logger: SapoLog.recording,
            failureLanguage: selectedLanguage
        )
    }

    /// Stable priority order (ElevenLabs first) matching the historical
    /// if/else chains in toggle/pause/abort.
    private var streamingContexts: [StreamingEngineContext] {
        [elevenLabsRealtimeContext, fluxContext]
    }

    /// The context whose session is streaming right now, if any.
    private var activeStreamingContext: StreamingEngineContext? {
        streamingContexts.first { $0.session.isStreaming }
    }

    /// The context the NEXT dictation will use, when the current selection is
    /// a streaming mode.
    private var selectedStreamingContext: StreamingEngineContext? {
        if isElevenLabsRealtimeSelected { return elevenLabsRealtimeContext }
        if isDeepgramFluxLiveSelected { return fluxContext }
        return nil
    }

    // MARK: - Initial State

    private func checkInitialState() {
        appState = isEngineReady(currentEngine) ? .idle : .noModel
    }

    // MARK: - WhisperKit Methods

    /// Carga el modelo de WhisperKit seleccionado
    func loadWhisperKitModel() async {
        do {
            try await whisperKitTranscriber.loadModel(currentWhisperKitModel, language: selectedLanguage)
            // R4: an on-demand reload can finish mid-recording — only leave
            // the "no model" state, never clobber an active session state.
            if case .noModel = appState {
                appState = .idle
            }
        } catch {
            let errorMsg = error.localizedDescription
            SapoLog.recording.error("WhisperKit load failed error=\(errorMsg, privacy: .public)")
            // Mid-recording reload failures surface at stop time through the
            // normal transcription failure path; do not clobber the session.
            guard activeRecordingSessionID == nil else { return }
            let displayMessage = "error.whisperkit.model_load".localized(errorMsg)
            appState = .error(ErrorState(message: displayMessage))

            // Show the error briefly, then return to noModel for retry — but
            // only while THIS error is still showing; a newer, different
            // error inside the window must not be clobbered.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .error(let state) = self.appState, state.message == displayMessage {
                    self.checkInitialState()
                }
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

    func setDeepgramMode(_ mode: DeepgramTranscriptionMode) {
        selectedDeepgramMode = mode.rawValue
        checkInitialState()
    }

    func setElevenLabsMode(_ mode: ElevenLabsTranscriptionMode) {
        selectedElevenLabsMode = mode.rawValue
        checkInitialState()
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
        } else if let context = activeStreamingContext {
            SapoLog.hotkey.info(
                "Recording toggle route=stop-\(context.snapshotPrefix, privacy: .public) count=\(toggleCount, privacy: .public)"
            )
            requestStopStreamingAndTranscribe(context)
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

        if isSelectedEngineBusy {
            // History re-runs keep appState clean, so the busy check above does
            // not catch them. Block here so a new recording can't collide with
            // an in-flight transcription on the same engine.
            SapoLog.hotkey.info("Hotkey ignored while the selected engine is busy")
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

    /// True while the engine selected for live dictation is mid-flight on any
    /// path (live or history reprocess). Used by the hotkey start guard so a
    /// new recording can't collide with an in-progress transcription even when
    /// appState is kept clean during a history re-run.
    private var isSelectedEngineBusy: Bool {
        engineSessions(for: currentEngine).isBusy
    }

    /// Toggle de pausa/resume (llamado por el botón del overlay)
    func togglePause() {
        if let context = activeStreamingContext {
            let session = context.session
            if session.isPaused {
                do {
                    try session.resumeRecording()
                    overlayManager.updateState(.recording(duration: session.recordingDuration))
                } catch {
                    context.logger.error(
                        "\(context.logLabel, privacy: .public) resume failed error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            } else {
                session.pauseRecording()
                overlayManager.updateState(.paused(duration: session.recordingDuration))
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
                SapoLog.recording.error("Capture resume failed error=\(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Pause
            audioRecorder.pauseRecording()
            overlayManager.updateState(.paused(duration: audioRecorder.recordingDuration))
            overlayManager.updateAudioLevel(0)
        }
    }

    /// Inicia la grabacion.
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
        let missingPermissions = PermissionService.shared.missingRecordingPermissions()

        guard missingPermissions.isEmpty else {
            activeRecordingSessionID = nil
            SapoLog.recording.warning("Recording blocked by missing permissions")
            PermissionService.shared.showRequirementsWindow(force: true)
            return
        }

        // Verificar que el motor actual tiene modelo cargado
        let isReady = isEngineReady(engine)

        // R4: a model unloaded after idle reloads on demand — recording starts
        // immediately and the transcription awaits the reload at stop time.
        let canReloadOnDemand =
            engine == .whisperLocal
            && whisperKitTranscriber.downloadedModels.contains(currentWhisperKitModel)
            && !whisperKitTranscriber.isTranscribing

        guard isReady || canReloadOnDemand else {
            activeRecordingSessionID = nil
            appState = .noModel
            SapoLog.recording.warning("Recording blocked because engine is not ready")
            return
        }

        if !isReady {
            SapoLog.recording.info("WhisperKit reloading on demand after idle unload")
            Task { await self.loadWhisperKitModel() }
        }

        // R7: offline fast-fail before opening the mic — cloud engines would
        // otherwise burn their full network timeout after the dictation.
        if engine.requiresInternet && NetworkReachability.shared.isOffline {
            activeRecordingSessionID = nil
            // No session/audio here, so a Retry must start fresh, not retranscribe
            // a stale prior failure ([6]).
            clearFailedRetryState()
            SapoLog.recording.warning("Recording blocked offline engine=\(engine.rawValue, privacy: .public)")
            presentTranscriptionFailure(
                TranscriptionFailure(
                    kind: .network, engine: engine.displayName,
                    technicalDetail: "offline fast-fail before start"
                )
            )
            return
        }

        // Guardar la app activa para volver a ella despues de pegar
        PasteManager.savePreviousApp()

        // Primary-mic sync: a pinned explicit mic becomes the system default
        // input NOW. Opening a non-default device pays full route setup on
        // every take (on AirPods, the whole Bluetooth handshake); keeping app
        // and system aligned makes the fast path the only path. The route
        // settle window this may open is honored by the recorder start below.
        if PreferredMicrophoneCoordinator.shared.ensureSystemDefaultMatchesSelection() {
            SapoLog.recording.info("Recording start synced system default input to primary mic")
        }

        // Mostrar overlay PRIMERO para feedback visual inmediato
        sessionPeakAudioLevel = 0
        sessionLevelTrackingStartedAt = triggerTime
        appState = .recording

        overlayManager.updateState(.recording(duration: 0))
        // Until the first real buffer lands, the pill says "connecting <mic>"
        // instead of showing a dead flat waveform — Bluetooth inputs spend
        // 1–3 s renegotiating (A2DP→HFP) before any signal flows.
        overlayManager.setMicConnecting(deviceName: effectiveInputDisplayName())

        // Continue-previous offer: only the batch recorder can prepend audio
        // at stop time (streaming engines transcribe live). Starts opted-out.
        resumeMergeRequested = false
        let isBatchEngine = !isElevenLabsRealtimeSelected && !isDeepgramFluxLiveSelected
        if isBatchEngine, let resumable = validResumableDictation {
            overlayManager.setResumeOffer(durationLabel: Self.formatResumeDuration(resumable.duration))
        } else {
            overlayManager.setResumeOffer(durationLabel: nil)
        }
        let uiReadyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
        SapoLog.recording.info("Recording UI ready in \(uiReadyMs, privacy: .public)ms")
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-ui-ready",
            context: diagnosticContext(extra: "session=\(sessionID) uiReadyMs=\(uiReadyMs)")
        )

        let mic = selectedMicrophone
        let playSound = playSoundEnabled
        isStartPending = true
        // El beep de inicio suena antes de abrir el micrófono en todos los
        // motores: feedback instantáneo del hotkey. El AutoDucking baja el
        // volumen en una rampa suave que arranca al instante, así el beep
        // se oye al comienzo de la bajada sin un corte brusco.
        if playSound {
            SoundManager.shared.play(.startRecording)
        }
        if let context = selectedStreamingContext {
            let language = selectedLanguage
            startCaptureSession(
                sessionID: sessionID,
                owner: context.owner,
                logLabel: context.logLabel,
                snapshotPrefix: context.snapshotPrefix,
                playSound: playSound,
                triggerTime: triggerTime,
                prepare: { context.session.cancel() },
                start: { try await context.session.start(microphone: mic, language: language) }
            )
        } else {
            startCaptureSession(
                sessionID: sessionID,
                owner: .batchRecorder,
                logLabel: "Recording",
                snapshotPrefix: "recording",
                playSound: playSound,
                triggerTime: triggerTime,
                prepare: { if isStartPending { audioRecorder.cancelPendingSetup() } },
                start: { try await self.startRecorderWithRecovery(microphone: mic) }
            )
        }
    }

    /// Cancelación rápida (tecla Esc): guarda el audio de la sesión activa en
    /// Historial para re-transcribirlo después, sin transcribir ni pegar nada.
    func cancelActiveDictation() {
        if isStartPending {
            SapoLog.hotkey.info("Dictation cancelled route=pending-start")
            cancelPendingRecordingStart()
            return
        }

        guard !isStopPending, isAnyRecorderActive else { return }

        SapoLog.hotkey.info("Dictation cancelled route=active \(self.diagnosticContext(), privacy: .public)")
        let result = abortActiveCapturePreservingAudio(
            reasonLog: "user_cancelled",
            failureKind: .userCancelled,
            storeRetryState: false
        )
        if result.preservedAudio {
            // The audio survived in History — say so, or the cancel reads as
            // "everything I said is gone".
            overlayManager.showCancelled()
        } else {
            overlayManager.updateState(.hidden)
        }
        checkInitialState()
    }

    private func cancelPendingRecordingStart() {
        guard isStartPending else { return }

        audioRecorder.cancelPendingSetup()
        for context in streamingContexts {
            context.session.cancel()
        }
        startRecordingTask?.cancel()
        startRecordingTask = nil
        isStartPending = false
        activeRecordingSessionID = nil
        overlayManager.updateAudioLevel(0)
        overlayManager.updateState(.hidden)
        captureCoordinator.endActiveCapture()
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
            "state=\(appState.diagnosticName) engine=\(currentEngine.rawValue) deepgramMode=\(currentDeepgramMode.rawValue) elevenLabsMode=\(currentElevenLabsMode.rawValue) startPending=\(isStartPending) stopPending=\(isStopPending) audioRecording=\(audioRecorder.isRecording) fluxStreaming=\(deepgramFluxTranscriber.isStreaming) elevenLabsRealtimeStreaming=\(elevenLabsRealtimeTranscriber.isStreaming) audioPaused=\(audioRecorder.isPaused) fluxPaused=\(deepgramFluxTranscriber.isPaused) elevenLabsRealtimePaused=\(elevenLabsRealtimeTranscriber.isPaused) duration=\(Int(recordingDuration)) recordingSession=\(recordingSession) transcriptionSession=\(transcriptionSession) mic=\(selectedMicrophone)\(suffix)"
    }

    func handleStaleTranscriptionCompletion(audioURL: URL, sessionID: UInt64) {
        SapoLog.recording.warning(
            "Ignoring stale transcription completion session=\(sessionID, privacy: .public)"
        )
        audioRecorder.deleteRecording(at: audioURL)
    }

    /// Shared stop-request path (L6): the UI reacts immediately; the tail
    /// padding only gates when the capture stops pulling buffers, not the
    /// rest of the pipeline.
    private func requestStopAndTranscribe(
        logLabel: String,
        snapshotPrefix: String,
        logger: Logger,
        perfEngine: String,
        stop: @escaping @MainActor (DictationPerfTimeline) -> Void
    ) {
        guard !isStopPending else {
            SapoLog.hotkey.info("Hotkey ignored because \(logLabel, privacy: .public) stop is already pending")
            return
        }
        isStopPending = true

        let tailPadding = Self.stopTailPadding
        let stopRequestTime = CFAbsoluteTimeGetCurrent()
        let perf = DictationPerfTimeline(engine: perfEngine)
        logger.info(
            "\(logLabel, privacy: .public) stop hotkey accepted tailPadding=\(Int(tailPadding * 1000), privacy: .public)ms"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "\(snapshotPrefix)-stop-requested",
            context: diagnosticContext(extra: "tailPaddingMs=\(Int(tailPadding * 1000))"),
            force: true
        )

        appState = .processing
        overlayManager.updateState(.transcribing)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(tailPadding * 1_000_000_000))
            await MainActor.run {
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - stopRequestTime) * 1000)
                logger.info("\(logLabel, privacy: .public) stop tail elapsed=\(elapsed, privacy: .public)ms")
                perf.markTailDone()
                stop(perf)
            }
        }
    }

    private func requestStopRecordingAndTranscribe() {
        requestStopAndTranscribe(
            logLabel: "Recording",
            snapshotPrefix: "recording",
            logger: SapoLog.recording,
            perfEngine: currentEngine.rawValue
        ) { perf in
            self.stopRecordingAndTranscribe(perf: perf)
        }
    }

    private func requestStopStreamingAndTranscribe(_ context: StreamingEngineContext) {
        requestStopAndTranscribe(
            logLabel: context.logLabel,
            snapshotPrefix: context.snapshotPrefix,
            logger: context.logger,
            perfEngine: context.engineName
        ) { perf in
            self.stopStreamingAndTranscribe(context, perf: perf)
        }
    }

    private func stopStreamingAndTranscribe(_ context: StreamingEngineContext, perf: DictationPerfTimeline? = nil) {
        isStopPending = false
        defer { captureCoordinator.endActiveCapture() }

        if playSoundEnabled {
            // Restaurar el volumen antes del beep para que no suene ducked
            AutoDuckingManager.shared.restore()
            SoundManager.shared.play(.stopRecording)
        }

        let sessionID = activeRecordingSessionID ?? nextRecordingSessionID()
        activeRecordingSessionID = nil
        activeTranscriptionSessionID = sessionID
        context.logger.info("\(context.logLabel, privacy: .public) stopping session=\(sessionID, privacy: .public)")

        let request = TranscriptionPipeline.Request(
            sessionID: sessionID,
            engine: context.engine,
            engineName: context.engineName,
            source: context.source,
            failureLanguage: context.failureLanguage,
            snapshotPrefix: "\(context.snapshotPrefix)-transcription",
            logger: context.logger,
            perf: perf
        )

        let session = context.session
        Task { @MainActor in
            perf?.markFinalizeDone()
            await transcriptionPipeline.run(request) {
                let result = try await session.stop()
                return TranscriptionPipeline.EngineOutput(
                    transcript: result.transcript,
                    audioURL: result.audioURL,
                    duration: result.duration,
                    language: result.language
                )
            } captureResultOnFailure: {
                session.lastCaptureResult.map { ($0.audioURL, $0.duration) }
            }
        }
    }

    /// Detiene la grabacion y transcribe
    private func stopRecordingAndTranscribe(perf: DictationPerfTimeline? = nil) {
        isStopPending = false

        if playSoundEnabled {
            // Restaurar el volumen antes del beep para que no suene ducked
            AutoDuckingManager.shared.restore()
            SoundManager.shared.play(.stopRecording)
        }

        let engine = currentEngine
        let language = selectedLanguage
        let duration = recordingDuration
        let sessionID = activeRecordingSessionID ?? nextRecordingSessionID()
        activeRecordingSessionID = nil
        activeTranscriptionSessionID = sessionID

        Task { @MainActor in
            // All engines: stop recording, get audio file, transcribe.
            // The finalize runs on the audio queue so the MainActor stays free.
            let stoppedURL = await audioRecorder.stopRecordingAsync()?.audioURL
            captureCoordinator.endActiveCapture()

            guard let audioURL = stoppedURL else {
                activeTranscriptionSessionID = nil
                let failure = TranscriptionFailure(kind: .audioEmpty)
                SapoLog.recording.error(
                    "Recording produced no audio file \(failure.diagnosticCode, privacy: .public)")
                presentTranscriptionFailure(failure)
                return
            }
            perf?.markFinalizeDone()

            if let diagnostics = audioRecorder.lastCaptureDiagnostics, !diagnostics.receivedInput {
                SapoLog.recording.warning(
                    "Dropping empty recording after device switch bytes=\(diagnostics.fileSizeBytes, privacy: .public) input=\(diagnostics.selectedDeviceUID, privacy: .public)"
                )
                audioRecorder.deleteRecording(at: audioURL)
                activeTranscriptionSessionID = nil
                // The audio was just deleted, so the (retryable) .recordingInterrupted
                // must not let Retry retranscribe a STALE prior session's audio ([6]).
                clearFailedRetryState()
                presentTranscriptionFailure(TranscriptionFailure(kind: .recordingInterrupted))
                return
            }

            // Continue-previous merge: prepend the offered take before
            // transcription so one transcript covers both. On merge failure
            // the current take still transcribes alone — never lose new audio
            // over an enhancement.
            let mergeResumable = resumeMergeRequested ? validResumableDictation : nil
            resumeMergeRequested = false

            // No-speech fast path: the whole session peaked below the silence
            // threshold, so skip the network entirely. The WAV stays on disk
            // (guardrail) and no failed history row is created. A requested
            // merge bypasses the gate — the previous take carries the speech.
            if sessionLooksSilent && mergeResumable == nil {
                activeTranscriptionSessionID = nil
                SapoLog.recording.info(
                    "No-speech fast path engaged engine=\(engine.rawValue, privacy: .public) peakDb=\(self.approximateSessionPeakDb, privacy: .public)"
                )
                presentTranscriptionFailure(
                    TranscriptionFailure(
                        kind: .emptyTranscription, engine: engine.displayName,
                        technicalDetail: "local silence gate peakDb=\(approximateSessionPeakDb)"
                    )
                )
                return
            }

            var effectiveAudioURL = audioURL
            var effectiveDuration = duration
            if let mergeResumable {
                do {
                    let mergedURL = try AudioFileMerger.merge(first: mergeResumable.audioURL, second: audioURL)
                    audioRecorder.deleteRecording(at: audioURL)
                    effectiveAudioURL = mergedURL
                    effectiveDuration = mergeResumable.duration + duration
                    resumableDictation = nil
                    // The merged take supersedes the recovered/cancelled row;
                    // keeping it would duplicate the same audio in History.
                    historyManager.delete(id: mergeResumable.historyId)
                    SapoLog.recording.info(
                        "Continue-previous merge applied durationSec=\(Int(effectiveDuration), privacy: .public)"
                    )
                } catch {
                    SapoLog.recording.error(
                        "Continue-previous merge failed, transcribing current take only error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            let request = TranscriptionPipeline.Request(
                sessionID: sessionID,
                engine: engine,
                engineName: historyEngineName(for: engine),
                source: engine.rawValue,
                failureLanguage: language,
                snapshotPrefix: "transcription",
                logger: SapoLog.recording,
                perf: perf
            )

            let transcriptionURL = effectiveAudioURL
            let transcriptionDuration = effectiveDuration
            await transcriptionPipeline.run(request) {
                let transcript = try await self.transcribeAudio(at: transcriptionURL, using: engine, language: language)
                return TranscriptionPipeline.EngineOutput(
                    transcript: transcript,
                    audioURL: transcriptionURL,
                    duration: transcriptionDuration,
                    language: language
                )
            } captureResultOnFailure: {
                (transcriptionURL, transcriptionDuration)
            }
        }
    }

    /// Retry transcription with the last failed audio (fix #19: smart engine fallback)
    /// Drops any pending failed-retry state. Called when a session ends without
    /// persisting a retryable failure (empty / interrupted / offline fast-fail),
    /// so a later Retry cannot retranscribe and paste a STALE prior session's
    /// audio (the interrupted/offline paths leave no valid audio to retry).
    private func clearFailedRetryState() {
        lastFailedAudioURL = nil
        lastFailedHistoryId = nil
    }

    func retryTranscription() {
        guard let audioURL = lastFailedAudioURL else {
            guard canStartRecordingFromHotkey() else { return }
            startRecording()
            return
        }
        guard !isRetryInFlight else { return }
        isRetryInFlight = true

        appState = .processing
        overlayManager.updateState(.transcribing)

        let engine = currentEngine
        let language = selectedLanguage
        let duration = lastFailedHistoryId.flatMap { historyId in
            historyManager.duration(for: historyId)
        }

        Task {
            defer { isRetryInFlight = false }
            do {
                let transcription = try await transcribeAudio(at: audioURL, using: engine, language: language)
                let aiResult = await postProcessTranscript(
                    transcription,
                    source: "retry",
                    duration: duration
                )

                deliverTranscription(aiResult.finalText, perf: nil)

                // Update history entry in place; the retry may run on a
                // different engine than the failed attempt.
                if let historyId = lastFailedHistoryId {
                    historyManager.updateRetranscription(
                        id: historyId,
                        engine: historyEngineName(for: engine),
                        finalText: aiResult.finalText,
                        rawText: aiResult.rawText,
                        aiStatus: aiResult.status,
                        aiModel: aiResult.model,
                        aiMode: aiResult.mode,
                        aiError: aiResult.error
                    )
                    lastCompletedHistoryId = historyId
                }
                lastFailedAudioURL = nil
                lastFailedHistoryId = nil

            } catch {
                let failure = TranscriptionFailure.from(error, engine: engine.displayName)
                presentTranscriptionFailure(failure)
                SapoLog.recording.error(
                    "Retry transcription failed \(failure.logSummary, privacy: .public)")
            }
        }
    }

    /// Depth counter for in-flight history re-runs. While > 0 the global
    /// dictation sinks and the polishing overlay are suppressed so a history
    /// retranscribe never drives the live UI or leaves appState stuck busy.
    private var historyReprocessingDepth = 0
    private var isReprocessingHistory: Bool { historyReprocessingDepth > 0 }

    func retranscribeHistoryEntry(_ entry: HistoryEntry, using engine: TranscriptionEngine) async -> HistoryRetranscriptionResult {
        guard let audioPath = entry.audioPath, FileManager.default.fileExists(atPath: audioPath) else {
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                errorMessage: "history.audio_missing_error".localized
            )
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        historyReprocessingDepth += 1
        defer { historyReprocessingDepth -= 1 }

        do {
            let transcription = try await transcribeAudio(at: audioURL, using: engine, language: entry.language)
            let aiResult = await postProcessTranscript(
                transcription,
                source: "history-retranscribe",
                duration: entry.duration
            )
            // Update the original row in place — no duplicate rows, no second
            // audio copy; the first engine is kept in original_engine.
            historyManager.updateRetranscription(
                id: entry.id,
                engine: historyEngineName(for: engine),
                finalText: aiResult.finalText,
                rawText: aiResult.rawText,
                aiStatus: aiResult.status,
                aiModel: aiResult.model,
                aiMode: aiResult.mode,
                aiError: aiResult.error
            )

            return HistoryRetranscriptionResult(entryId: entry.id, errorMessage: nil)
        } catch {
            // A failed retranscribe must not degrade the existing row; the
            // error only surfaces in the UI.
            return HistoryRetranscriptionResult(
                entryId: entry.id,
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

        let aiResult = await transcriptPostProcessor.process(rawText: sourceText, duration: entry.duration)
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

        // The manual history path runs with force:true, so duration/length
        // skips never apply; only a fidelity rejection or a missing provider
        // can leave the transcript unchanged. Each gets a neutral notice — the
        // "action failed" error alert is reserved for real failures.
        switch aiResult.status {
        case .failed:
            return HistoryRetranscriptionResult(entryId: entry.id, errorMessage: aiResult.error)
        case .rejectedFidelity:
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                noticeMessage: "history.ai_polish_rejected_notice".localized
            )
        case .none, .skippedShort, .skippedDuration:
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                noticeMessage: "history.ai_polish_unavailable_notice".localized
            )
        case .applied:
            return HistoryRetranscriptionResult(entryId: entry.id)
        }
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

    /// Shared start path for the three capture flows. `prepare` runs
    /// synchronously before the task (cancel a stale setup); `start` opens the
    /// actual capture (recorder with recovery, or a streaming session).
    private func startCaptureSession(
        sessionID: UInt64,
        owner: AudioCaptureCoordinator.CaptureOwner,
        logLabel: String,
        snapshotPrefix: String,
        playSound: Bool,
        triggerTime: CFAbsoluteTime,
        prepare: () -> Void,
        start: @escaping () async throws -> Void
    ) {
        prepare()
        startRecordingTask?.cancel()
        startRecordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.captureCoordinator.beginCapture(owner)
            var recorderDidStart = false

            defer {
                self.isStartPending = false
                self.startRecordingTask = nil
                if !recorderDidStart {
                    self.captureCoordinator.endCapture(owner)
                }
            }

            do {
                try await start()
                recorderDidStart = true
                let readyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
                SapoLog.recording.info("\(logLabel, privacy: .public) input ready in \(readyMs, privacy: .public)ms")
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "\(snapshotPrefix)-input-ready",
                    context: self.diagnosticContext(extra: "session=\(sessionID) readyMs=\(readyMs)"),
                    force: true
                )
            } catch {
                if error is CancellationError {
                    return
                }
                guard self.activeRecordingSessionID == sessionID else {
                    SapoLog.recording.warning(
                        "Ignoring stale \(logLabel, privacy: .public) start failure session=\(sessionID, privacy: .public)"
                    )
                    return
                }
                self.activeRecordingSessionID = nil
                self.appState = .error(ErrorState(message: error.localizedDescription))
                self.overlayManager.showError(message: error.localizedDescription)
                AutoDuckingManager.shared.restore()
                if playSound && !self.isRecoverableInputStartError(error) {
                    SoundManager.shared.play(.error)
                }
                PerformanceDiagnostics.logRuntimeSnapshot(
                    reason: "\(snapshotPrefix)-input-failed",
                    context: self.diagnosticContext(
                        extra: "session=\(sessionID) error=\(error.localizedDescription)"
                    ),
                    force: true
                )
                SapoLog.recording.error(
                    "\(logLabel, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func startRecorderWithRecovery(microphone: String) async throws {
        let transport = AudioDeviceManager.shared.effectiveInputTransport(forSelectedUID: microphone)
        let retryBudget = transport == .bluetooth ? Self.bluetoothStartRetryBudget : Self.startRetryBudget
        if transport == .bluetooth {
            SapoLog.recording.info("Capture start on Bluetooth input, using extended timeouts")
        }
        let deadline = CFAbsoluteTimeGetCurrent() + retryBudget
        var lastFailure: Error = RecordingError.noInputAfterDeviceSwitch

        for attempt in 1...3 {
            guard !Task.isCancelled else { throw CancellationError() }

            do {
                let didStart = try await attemptRecorderStart(
                    microphone: microphone,
                    attempt: attempt,
                    minimumDelay: attempt == 1 ? 0 : Self.startRetryBackoffs[attempt - 2],
                    firstInputTimeout: transport == .bluetooth
                        ? Self.bluetoothFirstInputBufferTimeout : Self.firstInputBufferTimeout
                )
                if didStart {
                    if attempt > 1 {
                        SapoLog.recording.info("Capture recovered on retry after route transition")
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

            SapoLog.recording.warning(
                "Capture transient start failure reason=\(classification.reason, privacy: .public) attempt=\(attempt + 1, privacy: .public)/3 retryAfterMs=\(Int(retryDelay * 1000), privacy: .public)"
            )
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        }

        throw lastFailure
    }

    private func attemptRecorderStart(
        microphone: String,
        attempt: Int,
        minimumDelay: TimeInterval,
        firstInputTimeout: TimeInterval
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
        let receivedInput = await audioRecorder.waitForFirstInputBuffer(timeout: firstInputTimeout)
        if receivedInput {
            return true
        }

        let diagnostics = audioRecorder.currentCaptureDiagnostics()
        let inputDescription = diagnostics.selectedDeviceUID == "default" ? "system-default" : diagnostics.selectedDeviceUID
        SapoLog.recording.warning(
            "Capture no-input attempt=\(attempt, privacy: .public) timeoutMs=\(Int(firstInputTimeout * 1000), privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public) input=\(inputDescription, privacy: .public)"
        )
        return false
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

    // MARK: - No-speech handling

    /// First real signal (above digital silence) collapses the "connecting"
    /// label; genuinely quiet rooms still read above this because the level
    /// floor maps ambient noise well over zero.
    private static let micConnectedLevelThreshold: Float = 0.02

    /// Tracks the session peak and drives the live "no voice?" overlay hint.
    private func registerSessionAudioLevel(_ level: Float) {
        guard case .recording = appState else { return }
        sessionPeakAudioLevel = max(sessionPeakAudioLevel, level)

        if overlayManager.micConnectingName != nil, level > Self.micConnectedLevelThreshold {
            overlayManager.setMicConnecting(deviceName: nil)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - sessionLevelTrackingStartedAt
        // While the mic is still handshaking, "no voice?" would be misleading
        // — the connecting label owns that window.
        let hintEligible = overlayManager.micConnectingName == nil
        overlayManager.setNoSpeechHint(hintEligible && sessionLooksSilent && elapsed >= Self.noSpeechHintDelay)
    }

    /// Display name of the input the capture will open: the selected device,
    /// or whatever the system default resolves to right now.
    private func effectiveInputDisplayName() -> String {
        let deviceManager = AudioDeviceManager.shared
        let uid = selectedMicrophone
        let deviceID =
            uid == AudioDevice.systemDefault.uid
            ? deviceManager.getSystemDefaultInputDevice()
            : deviceManager.getDeviceID(for: uid)
        guard let deviceID, let name = deviceManager.getDeviceName(for: deviceID) else {
            return "overlay.mic_generic".localized
        }
        return name
    }

    /// Approximate session peak in dBFS, derived from the normalized level.
    private var approximateSessionPeakDb: Int {
        Int(sessionPeakAudioLevel * 60 - 60)
    }

    /// Single failure presenter: overlay dismiss time, retry affordance, and
    /// sound all derive from the failure kind. No-speech keeps the menu bar
    /// idle and skips the error sound.
    func presentTranscriptionFailure(_ failure: TranscriptionFailure) {
        let errorState = ErrorState(failure: failure)
        if errorState.isNoSpeech {
            checkInitialState()
        } else {
            appState = .error(errorState)
        }
        overlayManager.showError(errorState)
        if playSoundEnabled && !errorState.isNoSpeech {
            SoundManager.shared.play(.error)
        }
    }

    private func transcribeAudio(at audioURL: URL, using engine: TranscriptionEngine, language: String) async throws -> String {
        // Fail fast with a clear message if the recording is missing, empty, or corrupt.
        try AudioFileValidator.validate(audioURL)

        // R7: offline fast-fail instead of riding the request timeout. Covers
        // retry and history retranscription too; local engines are unaffected.
        if engine.requiresInternet && NetworkReachability.shared.isOffline {
            throw TranscriptionFailure(
                kind: .network, engine: engine.displayName,
                technicalDetail: "offline fast-fail before request"
            )
        }
        switch engine {
        case .whisperLocal:
            // R4: after an idle unload the reload kicked off at recording
            // start may still be in flight — await it before transcribing.
            if !whisperKitTranscriber.isModelLoaded {
                try await whisperKitTranscriber.loadModel(currentWhisperKitModel, language: language)
            }
            return try await whisperKitTranscriber.transcribe(audioURL: audioURL, language: language)
        case .deepgram:
            return try await deepgramTranscriber.transcribe(audioURL: audioURL, language: language)
        case .localAIServer:
            return try await localAIServerTranscriber.transcribe(audioURL: audioURL, language: language)
        case .elevenLabsScribe:
            // File transcription (retry, history, resume-merge) always uses
            // the batch endpoint even when the live mode is realtime:
            // replaying a finished file through the streaming WebSocket is
            // slower and strictly less accurate than batch on the same file.
            return try await elevenLabsTranscriber.transcribe(audioURL: audioURL, language: language)
        }
    }

    private func historyEngineName(for engine: TranscriptionEngine) -> String {
        switch engine {
        case .elevenLabsScribe:
            return currentElevenLabsMode.historyName
        case .localAIServer:
            return "Local AI Server · \(LocalAIServerConfiguration.storedModel)"
        default:
            return engine.displayName
        }
    }

    func postProcessTranscript(
        _ rawText: String,
        source: String,
        duration: TimeInterval?
    ) async -> TranscriptAIResult {
        let willAttemptPolish = transcriptPostProcessor.willAttemptPolish(rawText: rawText)
        if willAttemptPolish {
            // History re-runs reuse this helper but must not drive the live
            // dictation UI: suppress the busy state + overlay, keep diagnostics.
            if !isReprocessingHistory {
                appState = .polishing
                let usesLocalPolishBudget = PolishProviderConfiguration.configuredEndpointUsesLocalTimeoutBudget()
                // Same per-chunk sum the processor enforces — a chunked
                // transcript's countdown must not hit 0 mid-polish.
                overlayManager.updateState(
                    .polishing(
                        timeoutSeconds: TranscriptPostProcessor.totalPolishBudget(
                            forText: rawText,
                            duration: duration,
                            usesLocalBudget: usesLocalPolishBudget
                        )
                    )
                )
            }
            SapoLog.ai.info(
                "AI polish started source=\(source, privacy: .public) rawChars=\(rawText.count, privacy: .public)"
            )
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "ai-polish-start",
                context: diagnosticContext(extra: "source=\(source) rawChars=\(rawText.count)"),
                force: true
            )
        }

        let result = await transcriptPostProcessor.process(
            rawText: rawText,
            duration: duration
        )
        logAIResult(result, source: source)
        if !isReprocessingHistory {
            // Baseline for the completed pill's re-polish chips.
            lastDictationRawText = result.rawText
            lastDictationDuration = duration
        }
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

    /// Re-polishes the last dictation with the current (just toggled)
    /// language default: clipboard and History row update, no auto-paste —
    /// the first delivery already pasted, the user decides where this goes.
    func repolishLastTranscription() {
        guard case .idle = appState else { return }
        guard !isRepolishInFlight else { return }
        guard let rawText = lastDictationRawText, !rawText.isEmpty else { return }

        isRepolishInFlight = true
        let duration = lastDictationDuration
        let historyId = lastCompletedHistoryId
        let generation = dictationGeneration
        appState = .polishing
        let usesLocalPolishBudget = PolishProviderConfiguration.configuredEndpointUsesLocalTimeoutBudget()
        overlayManager.updateState(
            .polishing(
                timeoutSeconds: TranscriptPostProcessor.totalPolishBudget(
                    forText: rawText,
                    duration: duration,
                    usesLocalBudget: usesLocalPolishBudget
                )
            )
        )

        Task { @MainActor in
            defer { isRepolishInFlight = false }
            let result = await transcriptPostProcessor.process(
                rawText: rawText,
                duration: duration
            )
            logAIResult(result, source: "overlay-repolish")

            lastTranscription = result.finalText
            PasteManager.copyToClipboard(result.finalText)
            appState = .idle
            overlayManager.showCompleted(text: result.finalText)
            if playSoundEnabled {
                SoundManager.shared.play(.success)
            }

            // Only update the row if no newer dictation replaced it meanwhile.
            if let historyId, generation == dictationGeneration {
                historyManager.updateAIProcessing(
                    id: historyId,
                    finalText: result.finalText,
                    rawText: result.rawText,
                    aiStatus: result.status,
                    aiModel: result.model,
                    aiMode: result.mode,
                    aiError: result.error
                )
            }
        }
    }

    private func logAIResult(_ result: TranscriptAIResult, source: String) {
        let mode = result.mode ?? "none"
        let model = result.model ?? "none"
        let fallbackReason = result.error ?? "none"
        SapoLog.ai.info(
            "AI polish source=\(source, privacy: .public) status=\(result.status.rawValue, privacy: .public) mode=\(mode, privacy: .public) model=\(model, privacy: .public) elapsed=\(result.elapsedMs, privacy: .public)ms rawChars=\(result.rawText.count, privacy: .public) finalChars=\(result.finalText.count, privacy: .public) fallback=\(fallbackReason, privacy: .public)"
        )
    }

    /// L3: completed dictations persist off the paste path. The audio copy and
    /// the SQLite insert run on a background task; the UI is already idle.
    /// Failed dictations keep the synchronous path because the retry UI needs
    /// the persisted row id immediately.
    private func scheduleCompletedHistoryPersistence(
        from sourceURL: URL,
        engine: TranscriptionEngine,
        engineName: String?,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?
    ) {
        let generation = dictationGeneration
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let persistedEntry = self.persistHistoryEntry(
                from: sourceURL,
                engine: engine,
                engineName: engineName,
                language: language,
                duration: duration,
                aiResult: aiResult,
                status: "completed"
            )
            self.cleanupSourceAudioIfSafe(sourceURL: sourceURL, persistedEntry: persistedEntry)
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            SapoLog.performance.info("History persisted off paste path elapsed=\(elapsedMs, privacy: .public)ms")
            perf?.reportPersist(elapsedMs: elapsedMs)

            // Hand the row id back so an overlay re-polish can update it —
            // only if a newer dictation has not replaced this one.
            let rowID = persistedEntry.id
            guard rowID > 0 else { return }
            await MainActor.run {
                guard self.dictationGeneration == generation else { return }
                self.lastCompletedHistoryId = rowID
            }
        }
    }

    nonisolated private func persistHistoryEntry(
        from sourceURL: URL,
        engine: TranscriptionEngine,
        engineName: String? = nil,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult?,
        status: String,
        failureCode: String? = nil
    ) -> PersistedHistoryEntry {
        // Persist atomically through the manager: it copies the WAV and inserts
        // the row under `persistenceLock` so a concurrent save's orphan sweep
        // cannot delete the freshly copied audio before its row references it.
        let text = aiResult?.finalText ?? ""
        let result = historyManager.persistEntry(
            audioSource: sourceURL,
            engine: engineName ?? engine.displayName,
            language: language,
            duration: duration,
            text: text,
            rawText: aiResult?.rawText ?? text,
            status: status,
            aiStatus: aiResult?.status.rawValue ?? TranscriptAIStatus.none.rawValue,
            aiModel: aiResult?.model,
            aiMode: aiResult?.mode,
            aiError: aiResult?.error,
            failureCode: failureCode
        )

        return PersistedHistoryEntry(
            id: result.rowID,
            audioURL: result.audioPath.map { URL(fileURLWithPath: $0) },
            copiedAudioToHistory: result.copiedToHistory
        )
    }

    nonisolated private func cleanupSourceAudioIfSafe(sourceURL: URL, persistedEntry: PersistedHistoryEntry) {
        guard persistedEntry.copiedAudioToHistory else {
            SapoLog.recording.warning(
                "Keeping source audio because history copy was unavailable path=\(sourceURL.path, privacy: .private)"
            )
            return
        }

        audioRecorder.deleteRecording(at: sourceURL)
    }

    // MARK: - System sleep/wake (R1)

    /// Stops any active capture cleanly before the system sleeps. The WAV is
    /// preserved and a failed history row keeps the retry UI available; no
    /// network request is started against a dying connection.
    func handleSystemWillSleep() {
        SapoLog.lifecycle.info("System will sleep \(self.diagnosticContext(), privacy: .public)")

        if isStartPending {
            cancelPendingRecordingStart()
            return
        }
        guard !isStopPending, activeTranscriptionSessionID == nil else { return }
        guard abortActiveCapturePreservingAudio(reasonLog: "sleep").aborted else { return }

        overlayManager.updateState(.hidden)
        checkInitialState()
    }

    /// Best-effort cleanup for a normal app quit while recording. This is not a
    /// crash-recovery path; it only handles the delegate's graceful termination.
    func handleApplicationWillTerminate() {
        SapoLog.lifecycle.info("Application will terminate \(self.diagnosticContext(), privacy: .public)")

        if isStartPending {
            cancelPendingRecordingStart()
            return
        }

        guard activeTranscriptionSessionID == nil else { return }
        isStopPending = false
        _ = abortActiveCapturePreservingAudio(
            reasonLog: "terminate",
            failureKind: .userCancelled,
            storeRetryState: false
        )
    }

    /// A2: terminal capture interruption (mic died / route recovery failed).
    /// Aborts like the sleep path — WAV preserved, failed row for retry — but
    /// surfaces a clear retryable error instead of hiding the overlay.
    private func handleCaptureDeviceFailure(reason: String) {
        SapoLog.recording.error(
            "Capture device failure reason=\(reason, privacy: .public) \(self.diagnosticContext(), privacy: .public)"
        )
        guard !isStopPending, activeTranscriptionSessionID == nil else { return }
        guard abortActiveCapturePreservingAudio(reasonLog: reason).aborted else { return }

        presentTranscriptionFailure(
            TranscriptionFailure(kind: .recordingInterrupted, technicalDetail: reason)
        )
    }

    /// Shared abort for sleep, device-failure, cancel, and quit paths: stops
    /// whatever capture is active, preserves the WAV in a failed history row,
    /// and releases the mic. `aborted` is false when nothing was recording;
    /// `preservedAudio` reports whether a WAV actually reached History.
    @discardableResult
    private func abortActiveCapturePreservingAudio(
        reasonLog: String,
        failureKind: TranscriptionFailure.Kind = .recordingInterrupted,
        storeRetryState: Bool = true
    ) -> (aborted: Bool, preservedAudio: Bool) {
        let engine = currentEngine
        var interrupted: (audioURL: URL, duration: TimeInterval)?

        if let context = activeStreamingContext {
            if let result = context.session.abortPreservingAudio() {
                interrupted = (result.audioURL, result.duration)
            }
        } else if audioRecorder.isRecording {
            let duration = recordingDuration
            if let result = audioRecorder.stopRecording(logSummary: false) {
                interrupted = (result.audioURL, duration)
            }
        } else {
            return (false, false)
        }

        activeRecordingSessionID = nil
        captureCoordinator.endActiveCapture()
        AutoDuckingManager.shared.restore()
        overlayManager.updateAudioLevel(0)

        if let interrupted {
            let persistedEntry = persistHistoryEntry(
                from: interrupted.audioURL,
                engine: engine,
                engineName: historyEngineName(for: engine),
                language: selectedLanguage,
                duration: interrupted.duration,
                aiResult: nil,
                status: "failed",
                failureCode: TranscriptionFailure(
                    kind: failureKind, engine: engine.displayName
                ).diagnosticCode
            )
            if storeRetryState {
                lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
                lastFailedAudioURL = persistedEntry.audioURL ?? interrupted.audioURL
            } else {
                clearFailedRetryState()
            }
            // Every preserved take becomes the "continue previous dictation"
            // offer for the next recording (Esc, sleep, device death alike).
            if persistedEntry.id > 0 {
                resumableDictation = ResumableDictation(
                    historyId: persistedEntry.id,
                    audioURL: persistedEntry.audioURL ?? interrupted.audioURL,
                    duration: interrupted.duration,
                    capturedAt: Date()
                )
            }
            cleanupSourceAudioIfSafe(sourceURL: interrupted.audioURL, persistedEntry: persistedEntry)
            SapoLog.lifecycle.info(
                "Recording aborted reason=\(reasonLog, privacy: .public) durationSec=\(Int(interrupted.duration), privacy: .public)"
            )
        } else if !storeRetryState {
            clearFailedRetryState()
        }

        return (true, interrupted != nil)
    }

    /// Re-validates the pieces that go stale across sleep cycles: the hotkey
    /// event tap and the audio device/preflight caches.
    func handleSystemDidWake() {
        SapoLog.lifecycle.info("System did wake \(self.diagnosticContext(), privacy: .public)")
        hotkeyManager.assertHotkeyAlive(reason: "wake")
        AudioInputPreflightManager.shared.preflightSoon(reason: "wake")
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
        engineSessions(for: currentEngine).canRecord(
            hasActiveTranscriptionSession: activeTranscriptionSessionID != nil,
            appIsBusyProcessing: appState.isBusyProcessing
        )
    }

    /// Formatea la duración de grabación
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - TranscriptionPipelineHost

extension SapoWhisperViewModel: TranscriptionPipelineHost {
    func isTranscriptionSessionCurrent(_ sessionID: UInt64) -> Bool {
        activeTranscriptionSessionID == sessionID
    }

    func clearActiveTranscriptionSession() {
        activeTranscriptionSessionID = nil
    }

    /// Final delivery of a successful dictation: clipboard, overlay, paste,
    /// idle state, and the success sound. Shared by the pipeline and retry.
    func deliverTranscription(_ finalText: String, perf: DictationPerfTimeline?) {
        dictationGeneration &+= 1
        lastCompletedHistoryId = nil
        lastTranscription = finalText
        PasteManager.copyToClipboard(finalText)
        overlayManager.showCopied(text: finalText)

        if autoPasteEnabled {
            PasteManager.simulatePaste { perf?.markPasteDone() }
        } else {
            perf?.markPasteDone(skipped: true)
        }

        appState = .idle
        if playSoundEnabled {
            SoundManager.shared.play(.success)
        }
    }

    func persistCompletedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?
    ) {
        scheduleCompletedHistoryPersistence(
            from: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: aiResult,
            perf: perf
        )
        lastFailedAudioURL = nil
        lastFailedHistoryId = nil
    }

    func persistFailedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        failure: TranscriptionFailure
    ) {
        let persistedEntry = persistHistoryEntry(
            from: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: nil,
            status: "failed",
            failureCode: failure.diagnosticCode
        )
        lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
        lastFailedAudioURL = persistedEntry.audioURL ?? audioURL
        cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
    }

    func logTranscriptionSnapshot(reason: String, extra: String) {
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: reason,
            context: diagnosticContext(extra: extra),
            force: true
        )
    }
}
