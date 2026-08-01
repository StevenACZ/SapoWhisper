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
    /// The local MLX model downloading/loading — drives the menu bar
    /// loading badge.
    var isLoadingLocalModel: Bool { mlxWhisperTranscriber.isLoading }
    /// Combine bridge for AppKit-side consumers (MenuBarStatusController)
    /// that need a publisher now that the transcriber has none.
    let isLoadingLocalModelSubject = CurrentValueSubject<Bool, Never>(false)

    // MARK: - AppStorage Properties

    /// New installs auto-detect the spoken language; every current engine
    /// (MLX Whisper, Local AI Server, Deepgram, ElevenLabs) supports detection natively.
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
    @AppStorage(Constants.StorageKeys.transcriptionEngine) var selectedEngine: String = TranscriptionEngine.mlxWhisper.rawValue
    @AppStorage(Constants.StorageKeys.mlxWhisperModel) var selectedMLXWhisperModel: String =
        MLXWhisperModel.largeV3Turbo.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) var selectedDeepgramMode: String = DeepgramTranscriptionMode.nova3.rawValue
    @AppStorage(Constants.StorageKeys.elevenLabsTranscriptionMode) var selectedElevenLabsMode: String =
        ElevenLabsTranscriptionMode.defaultMode.rawValue
    @AppStorage(Constants.StorageKeys.localAIServerModel) var selectedLocalAIServerModel: String =
        LocalAIServerConfiguration.defaultModel
    /// Optional backup engine: when the primary fails with a connectivity
    /// error (server down, timeout), the dictation retries on it once.
    @AppStorage(Constants.StorageKeys.fallbackTranscriptionEngine) var fallbackEngineRawValue: String = ""

    // MARK: - Managers

    let audioRecorder = AudioCaptureEngine(mode: .batch)
    let mlxWhisperTranscriber = MLXWhisperTranscriber()
    let hotkeyManager = HotkeyManager.shared
    let overlayManager = OverlayWindowManager.shared
    let deepgramTranscriber = DeepgramBatchTranscriber()
    let deepgramFluxTranscriber = DeepgramFluxLiveTranscriber()
    let elevenLabsTranscriber = ElevenLabsScribeTranscriber()
    let elevenLabsRealtimeTranscriber = ElevenLabsScribeRealtimeTranscriber()
    let localAIServerTranscriber = LocalAIServerTranscriber()
    private let historyManager = TranscriptionHistoryManager.shared
    private let transcriptPostProcessor = TranscriptPostProcessor()
    /// Dictation→History persistence + retry/re-polish row bookkeeping.
    private lazy var persister = DictationHistoryPersister(
        deleteSourceAudio: { [audioRecorder] in audioRecorder.deleteRecording(at: $0) }
    )
    /// Batch capture start with device-aware retry (Bluetooth budgets).
    private lazy var captureStartSupervisor = CaptureStartSupervisor(recorder: audioRecorder)
    /// Clipboard + synthetic Cmd+V delivery seam.
    private let paste: any PasteDelivering = SystemPasteDelivery()

    // Overlay re-polish support
    /// Raw transcript + duration of the last live dictation, kept so the
    /// completed pill can re-polish the same text (e.g. after toggling the
    /// translation chip).
    private var lastDictationRawText: String?
    private var lastDictationDuration: TimeInterval?
    private var isRepolishInFlight = false

    // Reentrancy guard for retryTranscription: a second Retry (double click /
    // repeated hotkey) before the in-flight retry resolves would transcribe and
    // paste the same audio twice. Set before the Task, cleared in its defer.
    private var isRetryInFlight = false

    private static let stopTailPadding: TimeInterval = 0.12
    private static let startHotkeyDebounce: TimeInterval = 0.35
    private var isStopPending = false
    private var startRecordingTask: Task<Void, Never>?
    private var selectedMLXModelLoadTask: Task<Void, Never>?
    private var isStartPending = false
    private var recordingSessionCounter: UInt64 = 0
    private var toggleRecordingCount: UInt64 = 0
    var activeRecordingSessionID: UInt64?
    var activeTranscriptionSessionID: UInt64?
    private var activeInputDeviceOverrideUID: String?

    /// In-flight batch transcription (post-stop, engine running). Its history
    /// row was pre-persisted as "transcribing", so Esc can cancel the engine
    /// call and resolve the row without losing the audio.
    private struct ActiveBatchTranscription {
        let sessionID: UInt64
        let historyId: Int64?
        let audioURL: URL
        let duration: TimeInterval
        let task: Task<Void, Never>
    }
    private var activeBatchTranscription: ActiveBatchTranscription?
    private var lastStartHotkeyTime: CFAbsoluteTime = 0
    /// A5: single owner of mic exclusivity (monitor suspend/resume, overlap assert).
    private let captureCoordinator = AudioCaptureCoordinator.shared
    /// C1: shared transcribe→polish→paste→persist flow for the three stop paths.
    private lazy var transcriptionPipeline = TranscriptionPipeline(host: self)

    // No-speech fast path: session peak tracking lives in the extracted
    // tracker; the host-protocol property below delegates to it.
    private var levelTracker = SessionAudioLevelTracker()

    var sessionLooksSilent: Bool { levelTracker.looksSilent }

    // MARK: - Resumable dictation (continue-previous merge)

    /// Offer/merge-request state for "continuar dictado anterior".
    private let resumableStore = ResumableDictationStore()

    /// Launch-time entry point: the orphan recovery adopted a crashed take.
    func offerResumableDictation(_ resumable: ResumableDictation) {
        resumableStore.offer(resumable)
    }

    // MARK: - Esc double-press cancel

    /// First Esc only warns (heartbeat + hint on the pill); the second within
    /// the window really cancels. Reset on every appState change and on
    /// pause/resume so an armed press never crosses a phase boundary.
    private var escapeCancelGate = EscapeCancelGate()

    func handleCancelKeyPress() {
        switch escapeCancelGate.registerPress() {
        case .armed:
            SapoLog.hotkey.info("Esc cancel armed, waiting for confirm")
            overlayManager.warnCancelArmed()
        case .confirmed:
            if appState == .processing {
                cancelActiveTranscription()
            } else {
                cancelActiveDictation()
            }
        }
    }

    // MARK: - Computed Properties

    var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .mlxWhisper
    }

    /// The variant the primary selection resolves to (engine + its live/file
    /// mode). Everything downstream runs on variants, so a live mode is never
    /// mistaken for its brand's file endpoint.
    var currentVariant: TranscriptionEngineVariant {
        .primary(
            engine: currentEngine,
            deepgramMode: currentDeepgramMode,
            elevenLabsMode: currentElevenLabsMode
        )
    }

    /// The configured backup, or nil when unset or on the primary's provider.
    ///
    /// The backup must be a DIFFERENT engine, not merely a different mode:
    /// readiness and reachability are provider-wide (one API key, one host), so
    /// a sibling mode is down exactly when the primary is and could never
    /// rescue anything. The live→file direction of one provider is already
    /// covered inside the streaming transcribers themselves.
    var fallbackVariant: TranscriptionEngineVariant? {
        guard let variant = TranscriptionEngineVariant.stored(fallbackEngineRawValue),
            variant.engine != currentVariant.engine
        else { return nil }
        return variant
    }

    /// The variant driving the dictation in flight. Set when recording starts
    /// — which is where the backup may take over — so stop, transcription and
    /// History all report the engine that actually ran, not the one selected.
    private var activeSessionVariant: TranscriptionEngineVariant?

    /// The variant the dictation in flight runs on, or the current selection
    /// outside a session (retry, history, settings summaries).
    var sessionVariant: TranscriptionEngineVariant { activeSessionVariant ?? currentVariant }

    /// Providers proved down recently, so the next dictation starts on the
    /// backup instead of opening the mic against a dead host.
    private var reachabilityLog = EngineReachabilityLog()

    /// In-flight health probe for the recording in progress. It runs while the
    /// user dictates, so its verdict is already in by stop time.
    private var reachabilityProbeTask: Task<Void, Never>?

    /// nil = no local model selected (the selection clears when its model is
    /// deleted); nothing downloads or loads again until an explicit pick.
    var currentMLXWhisperModel: MLXWhisperModel? {
        MLXWhisperModel(rawValue: selectedMLXWhisperModel)
    }

    var currentDeepgramMode: DeepgramTranscriptionMode {
        DeepgramTranscriptionMode(rawValue: selectedDeepgramMode) ?? .nova3
    }

    var currentElevenLabsMode: ElevenLabsTranscriptionMode {
        ElevenLabsTranscriptionMode(rawValue: selectedElevenLabsMode) ?? .defaultMode
    }

    private var isAnyRecorderActive: Bool {
        audioRecorder.isRecording || deepgramFluxTranscriber.isStreaming || elevenLabsRealtimeTranscriber.isStreaming
    }

    /// The concrete transcriber(s) backing one logical engine. Single source
    /// of truth for "which sessions make up this engine"; readiness/busy are
    /// derived from it uniformly, replacing the per-query `switch currentEngine`.
    func engineSessions(for engine: TranscriptionEngine) -> EngineSessions {
        switch engine {
        case .mlxWhisper:
            return EngineSessions(readiness: mlxWhisperTranscriber, busy: [mlxWhisperTranscriber])
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
        // Before setupHotkey: Carbon registers whatever the manager holds, and
        // an in-memory correction afterwards would never re-register.
        loadSavedSettings()
        setupHotkey()
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

        // Cargar modelo automaticamente si el motor es local y el modelo ya
        // esta en disco — una descarga solo la inicia una accion explicita.
        if currentEngine == .mlxWhisper, let model = currentMLXWhisperModel,
            mlxWhisperTranscriber.isModelDownloaded(model)
        {
            scheduleSelectedMLXModelLoad()
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
            self.resumableStore.mergeRequested = isActive
            SapoLog.recording.info("Resume-previous merge toggled active=\(isActive, privacy: .public)")
        }
        overlayManager.onOpenHistoryRequested = { [weak self] in
            Task { @MainActor in
                self?.openHistoryForLastTranscription()
            }
        }
        overlayManager.onOpenHistoryEntryRequested = { [weak self] entryId in
            Task { @MainActor in
                self?.openHistory(focusedOn: entryId)
            }
        }
        overlayManager.onQuickHistoryRetranscribe = { [weak self] entry in
            guard let self else { return nil }
            let result = await self.retranscribeHistoryEntry(entry, using: self.currentEngine)
            return result.errorMessage
        }
    }

    /// Quick history pill → History window focused on the browsed entry.
    private func openHistory(focusedOn entryId: Int64) {
        HistoryFocusRequest.pendingEntryID = entryId
        overlayManager.hide()
        NotificationCenter.default.post(name: HistoryFocusRequest.notification, object: nil)
        SapoLog.overlay.info("Open history from quick history pill entryId=\(entryId, privacy: .public)")
    }

    /// Result pill → History window focused on the entry that was just
    /// dictated. The pill collapses first so the overlay never floats over
    /// the opening window.
    private func openHistoryForLastTranscription() {
        HistoryFocusRequest.pendingEntryID = persister.lastCompletedHistoryId
        overlayManager.hide()
        NotificationCenter.default.post(name: HistoryFocusRequest.notification, object: nil)
        SapoLog.overlay.info("Open history from result pill entryId=\(self.persister.lastCompletedHistoryId ?? -1, privacy: .public)")
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
        hotkeyManager.currentKeyCode = HotkeyManager.sanitizedKeyCode(
            hotkeyKeyCode, fallback: Constants.Hotkey.defaultKeyCode)
        hotkeyManager.currentModifiers = HotkeyManager.sanitizedModifiers(
            hotkeyModifiers, fallback: Constants.Hotkey.defaultModifiers)
        hotkeyManager.currentDoubleTapModifier = HotkeyManager.sanitizedModifiers(
            hotkeyDoubleTapModifier, fallback: Constants.Hotkey.defaultDoubleTapModifier)
    }

    private func setupBindings() {
        // Observar estado de grabacion
        audioRecorder.isRecordingPublisher
            .sink { [weak self] isRecording in
                if isRecording {
                    self?.transition(to: .recording, reason: "capture-started")
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
        bindStreamingSession(deepgramFluxTranscriber, variant: .deepgramFluxLive)
        bindStreamingSession(elevenLabsRealtimeTranscriber, variant: .elevenLabsScribeRealtime)

        // Hooks del motor MLX (transcripcion, carga, modelo listo) — callback
        // hooks on the @Observable transcriber replace the old Combine sinks.
        mlxWhisperTranscriber.onTranscribingChanged = { [weak self] isTranscribing in
            guard let self else { return }
            if !isTranscribing {
                self.unloadMLXModelIfNotSelected()
                return
            }
            guard !self.isReprocessingHistory else { return }
            self.transition(to: .processing, reason: "mlx-transcribing")
        }
        mlxWhisperTranscriber.onLoadingChanged = { [weak self] isLoading in
            guard let self else { return }
            self.isLoadingLocalModelSubject.send(isLoading)
            if self.currentEngine == .mlxWhisper {
                DockIconManager.shared.updateIcon(for: self.appState, isModelLoading: isLoading)
            }
        }
        mlxWhisperTranscriber.onModelLoadedChanged = { [weak self] isLoaded in
            guard let self else { return }
            guard self.currentEngine == .mlxWhisper, isLoaded else { return }
            // An on-demand reload can finish mid-recording — only leave the
            // "no model" state so it never clobbers .recording/.processing/
            // .polishing (mirrors the guard in loadMLXWhisperModel()).
            if case .noModel = self.appState {
                self.transition(to: .idle, reason: "model-loaded")
            }
        }
        // A standalone Settings download that finishes for the ACTIVE
        // selection loads it right away, so dictation is ready without a
        // second tap. (loadModel de-dupes if a selection load already awaits
        // the same snapshot.)
        mlxWhisperTranscriber.onDownloadCompleted = { [weak self] model in
            guard let self, self.currentEngine == .mlxWhisper,
                model == self.currentMLXWhisperModel,
                !self.mlxWhisperTranscriber.isModelLoaded
            else { return }
            self.scheduleSelectedMLXModelLoad()
        }

        // Observar estado de transcripcion (ElevenLabs Scribe)
        elevenLabsTranscriber.$isTranscribing
            .sink { [weak self] isTranscribing in
                guard let self, !self.isReprocessingHistory else { return }
                if isTranscribing {
                    self.transition(to: .processing, reason: "elevenlabs-transcribing")
                }
            }
            .store(in: &cancellables)

        // Sincronizar estado con MenuBarIcon y DockIcon
        $appState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                // Actualizar icono del Dock usando el manager
                DockIconManager.shared.updateIcon(for: state, isModelLoading: self?.isLoadingLocalModel ?? false)
                // Auto-Ducking: reducir/restaurar volumen del sistema
                AutoDuckingManager.shared.handleStateChange(state)
                // Esc cancela el dictado mientras graba y también la
                // transcripción en vuelo (la fila ya está pre-persistida);
                // requiere doble pulsación vía EscapeCancelGate.
                self?.escapeCancelGate.reset()
                self?.hotkeyManager.setCancelKeyActive(state == .recording || state == .processing) {
                    [weak self] in
                    self?.handleCancelKeyPress()
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
    /// level, and overlay duration.
    ///
    /// The duration/level sinks are gated on the variant DRIVING the dictation,
    /// never on the selected engine: when the backup takes over, the live
    /// session that runs is not the selected one, and gating on the selection
    /// silently drops its meter and timer. That starves
    /// `registerSessionAudioLevel`, which is the only thing that clears the
    /// "connecting <mic>" label — so the pill sticks on "connecting" at 00:00
    /// for a dictation that is in fact recording fine.
    private func bindStreamingSession(
        _ session: any StreamingDictationSession,
        variant: TranscriptionEngineVariant
    ) {
        session.isStreamingPublisher
            .sink { [weak self] isStreaming in
                if isStreaming {
                    self?.transition(to: .recording, reason: "streaming-started")
                }
            }
            .store(in: &cancellables)

        session.recordingDurationPublisher
            .sink { [weak self] duration in
                guard self?.sessionVariant == variant else { return }
                self?.recordingDuration = duration
            }
            .store(in: &cancellables)

        session.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard self?.sessionVariant == variant else { return }
                self?.overlayManager.updateAudioLevel(level)
                self?.registerSessionAudioLevel(level)
            }
            .store(in: &cancellables)

        session.recordingDurationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self, self.sessionVariant == variant else { return }
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
        /// The live variant this context drives. Fixed per context — a Flux
        /// context is always Flux Live, whatever the Deepgram mode picker says
        /// — so a backup-driven live dictation labels itself honestly.
        let variant: TranscriptionEngineVariant
        /// `TranscriptionPipeline.Request` source tag.
        let source: String
        /// Snapshot-reason prefix, e.g. "flux" → "flux-stop-requested".
        let snapshotPrefix: String
        /// Human log label, e.g. "Flux" / "ElevenLabs realtime".
        let logLabel: String
        let logger: Logger
        /// Language recorded on a failed row when the stream dies.
        let failureLanguage: String

        var engine: TranscriptionEngine { variant.engine }
        /// History/perf label for rows and the perf timeline.
        var engineName: String { variant.displayName }
    }

    private var fluxContext: StreamingEngineContext {
        StreamingEngineContext(
            session: deepgramFluxTranscriber,
            owner: .fluxStreaming,
            variant: .deepgramFluxLive,
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
            variant: .elevenLabsScribeRealtime,
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

    /// The context that drives a live dictation on `variant`, or nil for the
    /// file-upload variants.
    private func streamingContext(for variant: TranscriptionEngineVariant) -> StreamingEngineContext? {
        switch variant {
        case .elevenLabsScribeRealtime:
            return elevenLabsRealtimeContext
        case .deepgramFluxLive:
            return fluxContext
        case .mlxWhisper, .localAIServer, .deepgramNova3, .elevenLabsScribeBatch:
            return nil
        }
    }

    // MARK: - Initial State

    private func checkInitialState() {
        // Settings cards recompute readiness from `onAppear`, so mid-dictation
        // the resulting .idle/.noModel would broadcast a false `.ended` and drop
        // the input-device override with the capture still live.
        guard activeRecordingSessionID == nil, activeTranscriptionSessionID == nil else { return }

        // A usable backup means dictation still works, so an unconfigured
        // primary must not park the app in "no model".
        let canDictate =
            isEngineReady(currentEngine)
            || fallbackVariant.map { isBackupEngineUsable($0) } == true
        transition(to: canDictate ? .idle : .noModel, reason: "check-initial-state")
    }

    /// Single choke point for appState writes: applies the change and logs
    /// any edge outside `AppState.canTransition` — observability first; no
    /// rejection until the table has survived live QA.
    private func transition(to newState: AppState, reason: String) {
        let oldState = appState
        if !appState.canTransition(to: newState) {
            SapoLog.lifecycle.warning(
                "appState transition outside table \(self.appState.diagnosticName, privacy: .public) -> \(newState.diagnosticName, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        DictationStateBroadcaster.broadcast(from: oldState, to: newState)
        appState = newState
        if oldState == .recording, newState != .recording {
            endInputDeviceOverrideIfNeeded()
        }
    }

    // MARK: - MLX Whisper Methods

    private func cancelSelectedMLXModelLoad() {
        selectedMLXModelLoadTask?.cancel()
        selectedMLXModelLoadTask = nil
    }

    private func unloadMLXModelIfNotSelected() {
        guard currentEngine != .mlxWhisper,
            mlxWhisperTranscriber.isModelLoaded || mlxWhisperTranscriber.isLoading
        else { return }
        mlxWhisperTranscriber.unloadModel()
    }

    private func scheduleSelectedMLXModelLoad() {
        cancelSelectedMLXModelLoad()
        selectedMLXModelLoadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.loadMLXWhisperModel()
        }
    }

    /// Carga el modelo MLX seleccionado (descarga si hace falta).
    func loadMLXWhisperModel() async {
        guard let model = currentMLXWhisperModel else { return }
        do {
            try await mlxWhisperTranscriber.loadModel(model)
            // R4: an on-demand reload can finish mid-recording — only leave
            // the "no model" state, never clobber an active session state.
            if case .noModel = appState {
                transition(to: .idle, reason: "mlx-load-recovered")
            }
        } catch is CancellationError {
            return
        } catch {
            let errorMsg = error.localizedDescription
            SapoLog.recording.error("MLX load failed error=\(errorMsg, privacy: .public)")
            // Mid-recording reload failures surface at stop time through the
            // normal transcription failure path; do not clobber the session.
            guard activeRecordingSessionID == nil else { return }
            transition(to: .error(ErrorState(message: errorMsg)), reason: "mlx-load-failed")

            // Show the error briefly, then return to noModel for retry — but
            // only while THIS error is still showing; a newer, different
            // error inside the window must not be clobbered.
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .error(let state) = self.appState, state.message == errorMsg {
                    self.checkInitialState()
                }
            }
        }
    }

    /// Cambia el modelo del motor MLX
    func setMLXWhisperModel(_ model: MLXWhisperModel) {
        cancelSelectedMLXModelLoad()
        selectedMLXWhisperModel = model.rawValue

        // Si el motor actual es MLX, recargar el modelo
        if currentEngine == .mlxWhisper {
            mlxWhisperTranscriber.unloadModel()
            scheduleSelectedMLXModelLoad()
        }
    }

    /// Cambia el motor de transcripcion
    func setEngine(_ engine: TranscriptionEngine) {
        cancelSelectedMLXModelLoad()
        selectedEngine = engine.rawValue

        if engine != .mlxWhisper {
            mlxWhisperTranscriber.unloadModel()
        }

        checkInitialState()

        // Volver al motor local solo recarga un modelo ya descargado — el
        // cambio de motor nunca inicia una descarga por si solo.
        if engine == .mlxWhisper && !mlxWhisperTranscriber.isModelLoaded,
            let model = currentMLXWhisperModel,
            mlxWhisperTranscriber.isModelDownloaded(model)
        {
            scheduleSelectedMLXModelLoad()
        }
    }

    /// Borra un modelo local del disco; si era el seleccionado, limpia la
    /// seleccion para que volver al motor local no lo re-descargue solo.
    func deleteMLXWhisperModel(_ model: MLXWhisperModel) {
        let wasSelected = currentMLXWhisperModel == model
        if wasSelected {
            cancelSelectedMLXModelLoad()
            mlxWhisperTranscriber.unloadModel()
        }
        mlxWhisperTranscriber.deleteDownloadedModel(model)
        if wasSelected {
            selectedMLXWhisperModel = ""
            if currentEngine == .mlxWhisper {
                checkInitialState()
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
    func toggleRecording(inputDeviceUID: String? = nil) {
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
            startRecording(inputDeviceUID: inputDeviceUID)
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
        escapeCancelGate.reset()
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
    func startRecording(inputDeviceUID: String? = nil) {
        if let inputDeviceUID {
            PreferredMicrophoneCoordinator.shared.beginExternalDefaultInputSession()
            activeInputDeviceOverrideUID = inputDeviceUID
        }
        var didEnterRecording = false
        defer {
            if !didEnterRecording {
                endInputDeviceOverrideIfNeeded()
            }
        }
        let triggerTime = CFAbsoluteTimeGetCurrent()
        let selectedVariant = currentVariant
        let sessionID = nextRecordingSessionID()
        lastStartHotkeyTime = triggerTime
        activeRecordingSessionID = sessionID
        SapoLog.hotkey.info(
            "Recording trigger accepted engine=\(selectedVariant.rawValue, privacy: .public) session=\(sessionID, privacy: .public)"
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

        // The backup may take the dictation before the mic even opens: a
        // primary that is not configured, is offline, or that a probe already
        // proved down hands the take over now, so the user never dictates into
        // an engine that cannot answer.
        guard let (variant, startedOnBackup) = resolveStartVariant(selected: selectedVariant) else {
            activeRecordingSessionID = nil
            transition(to: .noModel, reason: "start-engine-not-ready")
            SapoLog.recording.warning("Recording blocked because engine is not ready")
            return
        }
        if let startedOnBackup {
            SapoLog.recording.info(
                "Dictation starting on backup engine=\(variant.rawValue, privacy: .public) reason=\(startedOnBackup.rawValue, privacy: .public)"
            )
        }
        activeSessionVariant = variant
        let engine = variant.engine

        if engine == .mlxWhisper, !isEngineReady(.mlxWhisper) {
            SapoLog.recording.info("Local model reloading on demand after idle unload")
            Task {
                await self.loadMLXWhisperModel()
                self.unloadMLXModelIfNotSelected()
            }
        }

        // Probe the SELECTED primary while the user talks — whichever engine
        // ends up running. Its verdict is in by stop time, so a dead primary
        // is skipped with no wait, and a primary that came back clears its
        // entry and takes the next dictation again.
        startReachabilityProbe(for: selectedVariant)

        // R7: offline fast-fail before opening the mic — cloud engines would
        // otherwise burn their full network timeout after the dictation.
        if engine.requiresInternet && NetworkReachability.shared.isOffline {
            activeRecordingSessionID = nil
            activeSessionVariant = nil
            // No session/audio here, so a Retry must start fresh, not retranscribe
            // a stale prior failure ([6]).
            persister.clearRetryState()
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
        paste.savePreviousApp()

        // Cloud batch stops pay DNS+TLS inside stop→paste on a cold pool;
        // open the connection now, while the user is still dictating (the
        // streaming engines already amortize their handshake at start).
        switch variant {
        case .deepgramNova3:
            Task { await deepgramTranscriber.warmUpConnection() }
        case .elevenLabsScribeBatch:
            Task { await elevenLabsTranscriber.warmUpConnection() }
        default:
            break
        }

        // Primary-mic sync: a pinned explicit mic becomes the system default
        // input NOW. Opening a non-default device pays full route setup on
        // every take (on AirPods, the whole Bluetooth handshake); keeping app
        // and system aligned makes the fast path the only path. The route
        // settle window this may open is honored by the recorder start below.
        if inputDeviceUID == nil,
            PreferredMicrophoneCoordinator.shared.ensureSystemDefaultMatchesSelection()
        {
            SapoLog.recording.info("Recording start synced system default input to primary mic")
        }

        // Mostrar overlay PRIMERO para feedback visual inmediato
        levelTracker.beginSession(at: triggerTime)
        transition(to: .recording, reason: "start-optimistic")
        didEnterRecording = true

        overlayManager.updateState(.recording(duration: 0))
        // Until the first real buffer lands, the pill says "connecting <mic>"
        // instead of showing a dead flat waveform — Bluetooth inputs spend
        // 1–3 s renegotiating (A2DP→HFP) before any signal flows.
        overlayManager.setMicConnecting(
            deviceName: effectiveInputDisplayName(inputDeviceUID: inputDeviceUID)
        )

        // Continue-previous offer: only the batch recorder can prepend audio
        // at stop time (streaming engines transcribe live). Starts opted-out.
        resumableStore.mergeRequested = false
        if !variant.isStreaming, let resumable = resumableStore.validOffer {
            overlayManager.setResumeOffer(
                durationLabel: ResumableDictationStore.formatResumeDuration(resumable.duration))
        } else {
            overlayManager.setResumeOffer(durationLabel: nil)
        }
        let uiReadyMs = Int((CFAbsoluteTimeGetCurrent() - triggerTime) * 1000)
        SapoLog.recording.info("Recording UI ready in \(uiReadyMs, privacy: .public)ms")
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "recording-ui-ready",
            context: diagnosticContext(extra: "session=\(sessionID) uiReadyMs=\(uiReadyMs)")
        )

        let mic = inputDeviceUID ?? selectedMicrophone
        let playSound = playSoundEnabled
        isStartPending = true
        // El beep de inicio suena antes de abrir el micrófono en todos los
        // motores: feedback instantáneo del hotkey. El AutoDucking baja el
        // volumen en una rampa suave que arranca al instante, así el beep
        // se oye al comienzo de la bajada sin un corte brusco.
        if playSound {
            SoundManager.shared.play(.startRecording)
        }
        if let context = streamingContext(for: variant) {
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
                prepare: { audioRecorder.cancelPendingSetup() },
                start: { try await self.captureStartSupervisor.start(microphone: mic, targetEngine: engine) }
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
        activeSessionVariant = nil
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
        // A retry transcribes the failed row's HISTORY audio — going stale
        // must never delete a file the History still references.
        persister.cleanUpStaleAudio(audioURL)
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

        transition(to: .processing, reason: "stop-requested")
        overlayManager.updateState(.transcribing)

        Task {
            // Inherits MainActor from the enclosing @MainActor class.
            try? await Task.sleep(nanoseconds: UInt64(tailPadding * 1_000_000_000))
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - stopRequestTime) * 1000)
            logger.info("\(logLabel, privacy: .public) stop tail elapsed=\(elapsed, privacy: .public)ms")
            perf.markTailDone()
            stop(perf)
        }
    }

    private func requestStopRecordingAndTranscribe() {
        requestStopAndTranscribe(
            logLabel: "Recording",
            snapshotPrefix: "recording",
            logger: SapoLog.recording,
            perfEngine: sessionVariant.rawValue
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
        activeSessionVariant = nil
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
        let variant = context.variant
        let language = selectedLanguage
        Task { @MainActor in
            perf?.markFinalizeDone()
            await transcriptionPipeline.run(request) {
                do {
                    let result = try await session.stop()
                    self.settleReachability(variant.engine, reachable: true)
                    return TranscriptionPipeline.EngineOutput(
                        transcript: result.transcript,
                        audioURL: result.audioURL,
                        duration: result.duration,
                        language: result.language
                    )
                } catch {
                    return try await self.rescueFailedStream(
                        error, variant: variant, session: session, language: language)
                }
            } captureResultOnFailure: {
                session.lastCaptureResult.map { ($0.audioURL, $0.duration) }
            }
        }
    }

    /// A live dictation that died on a connectivity-class failure still holds
    /// its locally captured WAV, so the configured backup transcribes that
    /// instead of leaving the user a failed row. Without this the backup was
    /// dead letter for Flux and Scribe Realtime: the rescue only ever ran on
    /// the batch path.
    private func rescueFailedStream(
        _ error: Error,
        variant: TranscriptionEngineVariant,
        session: any StreamingDictationSession,
        language: String
    ) async throws -> TranscriptionPipeline.EngineOutput {
        let failure = TranscriptionFailure.from(error, engine: variant.displayName)
        guard !Task.isCancelled, EngineFailoverPolicy.isRescuable(failure) else { throw error }
        settleReachability(variant.engine, reachable: false)

        // A live dictation that already started ON the backup has nothing left
        // to fall back to; otherwise the backup's file endpoint is a genuinely
        // different path from the socket that just died.
        guard let backup = fallbackVariant, backup != variant, isBackupEngineUsable(backup),
            let capture = session.lastCaptureResult
        else { throw error }

        SapoLog.recording.warning(
            "Live engine failed \(failure.diagnosticCode, privacy: .public); rescuing capture with backup=\(backup.rawValue, privacy: .public)"
        )
        do {
            let rescued = try await transcribeOnBackup(
                at: capture.audioURL, backup: backup, language: language)
            return TranscriptionPipeline.EngineOutput(
                transcript: rescued.transcript,
                audioURL: capture.audioURL,
                duration: capture.duration,
                language: language,
                engineNameOverride: rescued.engineNameOverride
            )
        } catch let backupError {
            let backupFailure = TranscriptionFailure.from(backupError, engine: backup.displayName)
            SapoLog.recording.error(
                "Backup engine also failed \(backupFailure.logSummary, privacy: .public)")
            throw error
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

        let variant = sessionVariant
        let engine = variant.engine
        let language = selectedLanguage
        let duration = recordingDuration
        let sessionID = activeRecordingSessionID ?? nextRecordingSessionID()
        activeRecordingSessionID = nil
        activeSessionVariant = nil
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
                persister.clearRetryState()
                presentTranscriptionFailure(TranscriptionFailure(kind: .recordingInterrupted))
                return
            }

            // Continue-previous merge: prepend the offered take before
            // transcription so one transcript covers both. On merge failure
            // the current take still transcribes alone — never lose new audio
            // over an enhancement.
            let mergeResumable = resumableStore.consumeRequestedMerge()

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
                    resumableStore.clearOffer()
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

            // The finished capture is persisted BEFORE the engine runs: a
            // hang, crash, Esc, or force-quit during transcription can no
            // longer lose the audio — it is already a History row that the
            // pipeline finalizes (or the launch sweep resolves).
            let pending = persister.persistPending(
                audioURL: effectiveAudioURL,
                engine: engine,
                engineName: historyEngineName(for: variant),
                language: language,
                duration: effectiveDuration
            )

            var request = TranscriptionPipeline.Request(
                sessionID: sessionID,
                engine: engine,
                engineName: historyEngineName(for: variant),
                source: variant.rawValue,
                failureLanguage: language,
                snapshotPrefix: "transcription",
                logger: SapoLog.recording,
                perf: perf
            )
            if let pending {
                request.historyTarget = .finalizePending(historyId: pending.historyId)
            }

            let transcriptionURL = pending?.audioURL ?? effectiveAudioURL
            let transcriptionDuration = effectiveDuration
            let pipelineRequest = request
            let pipelineTask = Task {
                await self.transcriptionPipeline.run(pipelineRequest) {
                    let result = try await self.transcribeWithFallback(
                        at: transcriptionURL, primary: variant, language: language)
                    return TranscriptionPipeline.EngineOutput(
                        transcript: result.transcript,
                        audioURL: transcriptionURL,
                        duration: transcriptionDuration,
                        language: language,
                        engineNameOverride: result.engineNameOverride
                    )
                } captureResultOnFailure: {
                    (transcriptionURL, transcriptionDuration)
                }
            }
            activeBatchTranscription = ActiveBatchTranscription(
                sessionID: sessionID,
                historyId: pending?.historyId,
                audioURL: transcriptionURL,
                duration: transcriptionDuration,
                task: pipelineTask
            )
            await pipelineTask.value
            if activeBatchTranscription?.sessionID == sessionID {
                activeBatchTranscription = nil
            }
        }
    }

    /// Esc while "transcribing": aborts the in-flight engine call. The audio
    /// is already safe in History (pre-persisted row) — resolve that row as
    /// cancelled, offer it as the continue-previous take, and go idle. Only
    /// armed when the pre-persist succeeded; otherwise cancelling could still
    /// lose the temp WAV, so Esc stays inert like before.
    func cancelActiveTranscription() {
        guard let active = activeBatchTranscription,
            let historyId = active.historyId,
            activeTranscriptionSessionID == active.sessionID
        else { return }

        SapoLog.hotkey.info(
            "Transcription cancelled route=esc \(self.diagnosticContext(), privacy: .public)")
        historyManager.markTranscriptionFailed(
            id: historyId,
            failureCode: TranscriptionFailure(
                kind: .userCancelled, engine: sessionVariant.displayName
            ).diagnosticCode
        )
        resumableStore.offer(
            ResumableDictation(
                historyId: historyId,
                audioURL: active.audioURL,
                duration: active.duration,
                capturedAt: Date()
            ))
        // Staling the session first makes the cancelled pipeline exit through
        // the stale gate without touching UI, history, or the preserved WAV.
        activeTranscriptionSessionID = nil
        activeBatchTranscription = nil
        active.task.cancel()
        persister.clearRetryState()
        overlayManager.showCancelled()
        checkInitialState()
    }

    /// Runs the primary engine and, on a connectivity-class failure, retries
    /// once on the configured backup. When both fail, the PRIMARY failure is
    /// presented — it is the root cause the user should fix; the backup's
    /// failure only goes to the log.
    ///
    /// A primary already proved down — by the probe that ran while the user
    /// was still dictating, or by a failure minutes ago — is skipped outright:
    /// attempting it again would pay the full connect timeout before landing
    /// on the same rescue, which is exactly the wait the backup exists to
    /// remove.
    private func transcribeWithFallback(
        at audioURL: URL,
        primary: TranscriptionEngineVariant,
        language: String
    ) async throws -> (transcript: String, engineNameOverride: String?) {
        // Compared on the file variant, because that is what actually runs
        // here: rescuing an upload with the endpoint that just failed is no
        // rescue, and a dictation that already started on the backup has
        // nothing left to fall back to.
        let backup = fallbackVariant.flatMap {
            $0.fileTranscriptionVariant != primary.fileTranscriptionVariant
                && isBackupEngineUsable($0) ? $0 : nil
        }

        if let backup, reachabilityLog.isUnreachable(primary.engine) {
            SapoLog.recording.info(
                "Skipping primary known unreachable engine=\(primary.engine.rawValue, privacy: .public) backup=\(backup.rawValue, privacy: .public)"
            )
            return try await transcribeOnBackup(at: audioURL, backup: backup, language: language)
        }

        do {
            let transcript = try await transcribeAudio(at: audioURL, using: primary, language: language)
            settleReachability(primary.engine, reachable: true)
            return (transcript, nil)
        } catch {
            let failure = TranscriptionFailure.from(error, engine: primary.displayName)
            guard !Task.isCancelled, EngineFailoverPolicy.isRescuable(failure) else { throw error }
            settleReachability(primary.engine, reachable: false)
            guard let backup else { throw error }

            SapoLog.recording.warning(
                "Primary engine failed \(failure.diagnosticCode, privacy: .public); trying backup engine=\(backup.rawValue, privacy: .public)"
            )
            do {
                return try await transcribeOnBackup(at: audioURL, backup: backup, language: language)
            } catch let backupError {
                let backupFailure = TranscriptionFailure.from(backupError, engine: backup.displayName)
                SapoLog.recording.error(
                    "Backup engine also failed \(backupFailure.logSummary, privacy: .public)")
                throw error
            }
        }
    }

    /// Marked straight on the log rather than through `settleReachability`:
    /// the probe that call would cancel belongs to the PRIMARY, and a verdict
    /// about the backup says nothing about it.
    private func transcribeOnBackup(
        at audioURL: URL,
        backup: TranscriptionEngineVariant,
        language: String
    ) async throws -> (transcript: String, engineNameOverride: String?) {
        do {
            let transcript = try await transcribeAudio(at: audioURL, using: backup, language: language)
            reachabilityLog.markReachable(backup.engine)
            // History must name what ran, and a live-only backup rescues an
            // existing recording through its provider's file model.
            return (transcript, historyEngineName(for: backup.fileTranscriptionVariant))
        } catch {
            let failure = TranscriptionFailure.from(error, engine: backup.displayName)
            if EngineFailoverPolicy.isRescuable(failure) {
                reachabilityLog.markUnreachable(backup.engine)
            }
            throw error
        }
    }

    /// Whether the backup can plausibly transcribe right now. Internal so
    /// Settings can hint at a misconfigured backup.
    func isBackupEngineUsable(_ backup: TranscriptionEngineVariant) -> Bool {
        isEngineConfigured(backup) && !isKnownUnreachable(backup)
    }

    /// Configured to run at all: credentials present, or — for MLX — a model
    /// on disk, which is enough because `transcribeAudio` lazy-loads it.
    private func isEngineConfigured(_ variant: TranscriptionEngineVariant) -> Bool {
        guard variant.engine == .mlxWhisper else { return isEngineReady(variant.engine) }
        guard let model = currentMLXWhisperModel else { return false }
        return mlxWhisperTranscriber.isModelLoaded || mlxWhisperTranscriber.isModelDownloaded(model)
    }

    /// Being offline counts as unreachable rather than unusable: the engine is
    /// configured fine, the network it needs is simply gone — so a local
    /// backup takes over instead of the dictation failing.
    private func isKnownUnreachable(_ variant: TranscriptionEngineVariant) -> Bool {
        if variant.requiresInternet && NetworkReachability.shared.isOffline { return true }
        return reachabilityLog.isUnreachable(variant.engine)
    }

    /// What the failover policy knows about one variant right now.
    private func availability(of variant: TranscriptionEngineVariant) -> EngineFailoverPolicy.Availability {
        EngineFailoverPolicy.Availability(
            isUsable: isEngineConfigured(variant),
            isKnownUnreachable: isKnownUnreachable(variant)
        )
    }

    /// Which variant takes this dictation. A primary that is not configured,
    /// is offline, or that a probe already proved down hands the take to the
    /// backup BEFORE the mic opens — and a live backup then dictates natively
    /// instead of rescuing a finished recording. nil means nothing can record.
    private func resolveStartVariant(
        selected: TranscriptionEngineVariant
    ) -> (variant: TranscriptionEngineVariant, startedOnBackup: EngineFailoverPolicy.Reason?)? {
        // R4: a model unloaded after idle reloads on demand — the primary
        // stays usable and the transcription awaits the reload at stop time.
        let canReloadOnDemand =
            selected.engine == .mlxWhisper
            && currentMLXWhisperModel.map { mlxWhisperTranscriber.downloadedModels.contains($0) } == true
            && !mlxWhisperTranscriber.isTranscribing

        let primary = EngineFailoverPolicy.Availability(
            isUsable: isEngineConfigured(selected) || canReloadOnDemand,
            isKnownUnreachable: isKnownUnreachable(selected)
        )
        let backup = fallbackVariant

        switch EngineFailoverPolicy.decision(primary: primary, backup: backup.map { availability(of: $0) }) {
        case .primary:
            return (selected, nil)
        case .backup(let reason):
            guard let backup else { return (selected, nil) }
            return (backup, reason)
        case .blocked:
            return nil
        }
    }

    /// Records a reachability verdict that came from a REAL transcription, and
    /// cancels any probe still in flight.
    ///
    /// The probe is a cheap guess with a 3 s timeout; an actual request that
    /// succeeded or failed is the authority. Without this cancellation a probe
    /// resolving late overwrites the fresher verdict — a slow `/health` on a
    /// healthy server would strand the next 90 s of dictations on the backup,
    /// and a server answering `/health` while failing transcriptions would
    /// erase the very failure that must skip it.
    private func settleReachability(_ engine: TranscriptionEngine, reachable: Bool) {
        reachabilityProbeTask?.cancel()
        reachabilityProbeTask = nil
        if reachable {
            reachabilityLog.markReachable(engine)
        } else {
            reachabilityLog.markUnreachable(engine)
        }
    }

    /// Probes the primary in the background while the dictation runs. Only the
    /// Local AI Server has a cheap liveness endpoint; cloud providers are
    /// already covered by network reachability, and a local model cannot be
    /// "down". The verdict lands in `reachabilityLog` before stop time, unless
    /// a real transcription settles it first.
    private func startReachabilityProbe(for variant: TranscriptionEngineVariant) {
        reachabilityProbeTask?.cancel()
        reachabilityProbeTask = nil
        guard variant.engine == .localAIServer else { return }

        reachabilityProbeTask = Task { [weak self] in
            guard let isAlive = await self?.localAIServerTranscriber.probeReachability() else { return }
            guard let self, !Task.isCancelled else { return }
            if isAlive {
                self.reachabilityLog.markReachable(.localAIServer)
            } else {
                self.reachabilityLog.markUnreachable(.localAIServer)
                SapoLog.recording.warning(
                    "Local AI Server probe failed mid-dictation; the backup takes this take")
            }
        }
    }

    /// Retry transcription with the last failed audio (fix #19: smart engine fallback)
    func retryTranscription() {
        guard let audioURL = persister.lastFailedAudioURL else {
            guard canStartRecordingFromHotkey() else { return }
            startRecording()
            return
        }
        guard !isRetryInFlight else { return }
        guard activeTranscriptionSessionID == nil else { return }
        isRetryInFlight = true

        transition(to: .processing, reason: "retry-start")
        overlayManager.updateState(.transcribing)

        // A retry transcribes a FILE, so a live primary retries through its
        // provider's file model — and History must be told that, not the live
        // mode that is merely selected.
        let variant = currentVariant.fileTranscriptionVariant
        let language = selectedLanguage
        let historyId = persister.lastFailedHistoryId
        let duration = historyId.flatMap { historyManager.duration(for: $0) }
        let sessionID = nextRecordingSessionID()
        activeTranscriptionSessionID = sessionID

        // The retry rides the shared pipeline: same staleness gates and
        // delivery as a live stop, with the failed row refreshed in place
        // instead of inserting a new one.
        let request = TranscriptionPipeline.Request(
            sessionID: sessionID,
            engine: variant.engine,
            engineName: historyEngineName(for: variant),
            source: "retry",
            failureLanguage: language,
            snapshotPrefix: "retry-transcription",
            logger: SapoLog.recording,
            perf: nil,
            historyTarget: historyId.map { .updateExisting(historyId: $0) } ?? .insertNew
        )

        Task {
            defer { isRetryInFlight = false }
            await transcriptionPipeline.run(request) {
                let result = try await self.transcribeWithFallback(
                    at: audioURL, primary: variant, language: language)
                return TranscriptionPipeline.EngineOutput(
                    transcript: result.transcript,
                    audioURL: audioURL,
                    duration: duration,
                    language: language,
                    engineNameOverride: result.engineNameOverride
                )
            } captureResultOnFailure: {
                (audioURL, duration ?? 0)
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
        // The menu picks a brand, and an explicit choice never falls back.
        let variant = TranscriptionEngineVariant.fileVariant(for: engine)

        historyReprocessingDepth += 1
        defer { historyReprocessingDepth -= 1 }

        do {
            let transcription = try await transcribeAudio(at: audioURL, using: variant, language: entry.language)
            try Task.checkCancellation()
            let aiResult = await postProcessTranscript(
                transcription,
                source: "history-retranscribe",
                duration: entry.duration
            )
            // A cancel during the polish phase must not write the row either.
            try Task.checkCancellation()
            // Update the original row in place — no duplicate rows, no second
            // audio copy; the first engine is kept in original_engine.
            historyManager.updateRetranscription(
                id: entry.id,
                engine: historyEngineName(for: variant),
                finalText: aiResult.finalText,
                rawText: aiResult.rawText,
                aiStatus: aiResult.status,
                aiModel: aiResult.model,
                aiMode: aiResult.mode,
                aiError: aiResult.error
            )
            // The row is resolved now — keeping the continue-previous offer
            // would re-show the resume chip for a completed transcript and a
            // later merge would delete it.
            resumableStore.clearOffer(forHistoryId: entry.id)

            return HistoryRetranscriptionResult(entryId: entry.id, errorMessage: nil)
        } catch {
            // User-cancelled: the row stays untouched and no failure alert
            // shows. Task.isCancelled also covers engine errors thrown while
            // a cancellation was already pending (cloud URLError wrapping).
            if error is CancellationError || Task.isCancelled {
                return HistoryRetranscriptionResult(entryId: entry.id, errorMessage: nil)
            }
            // A failed retranscribe must not degrade the existing row; the
            // error only surfaces in the UI.
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                errorMessage: error.localizedDescription
            )
        }
    }

    /// `option` re-polishes with an explicit endpoint/model from the history
    /// menu; nil uses the globally configured provider.
    func polishHistoryEntry(
        _ entry: HistoryEntry,
        with option: PolishModelOption? = nil
    ) async -> HistoryRetranscriptionResult {
        let sourceText = (entry.hasRawTranscript ? entry.rawText : entry.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sourceText.isEmpty, entry.status == "completed" else {
            return HistoryRetranscriptionResult(
                entryId: entry.id,
                errorMessage: "history.ai_polish_missing_text".localized
            )
        }

        var provider: PolishProviderConfiguration?
        if let option {
            // The option was built from key-presence hints; resolving it here
            // reads the real key. A revoked key or emptied model falls out as
            // a normal error instead of silently polishing with the default.
            guard
                let configuration = PolishProviderConfiguration.configuration(
                    for: option.endpoint, model: option.model
                )
            else {
                return HistoryRetranscriptionResult(
                    entryId: entry.id,
                    errorMessage: "history.ai_polish_provider_unavailable".localized
                )
            }
            provider = configuration
        }

        let aiResult = await transcriptPostProcessor.process(
            rawText: sourceText, duration: entry.duration, provider: provider
        )
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
                self.transition(
                    to: .error(ErrorState(message: error.localizedDescription)),
                    reason: "capture-start-failed")
                self.overlayManager.showError(message: error.localizedDescription)
                AutoDuckingManager.shared.restore()
                if playSound && !CaptureStartSupervisor.isRecoverableInputStartError(error) {
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

    // MARK: - No-speech handling

    /// Tracks the session peak and drives the live "no voice?" overlay hint.
    private func registerSessionAudioLevel(_ level: Float) {
        guard case .recording = appState else { return }
        let now = CFAbsoluteTimeGetCurrent()
        levelTracker.register(level: level, now: now)

        if overlayManager.micConnectingInProgress, levelTracker.micConnectedCollapse(level: level) {
            overlayManager.setMicConnecting(deviceName: nil)
        }

        // While the mic is still handshaking, "no voice?" would be misleading
        // — the connecting label owns that window.
        overlayManager.setNoSpeechHint(
            levelTracker.noSpeechHintActive(
                connectingLabelVisible: overlayManager.micConnectingName != nil, now: now))
    }

    /// Display name of the input the capture will open: the selected device,
    /// or whatever the system default resolves to right now.
    private func effectiveInputDisplayName(inputDeviceUID: String? = nil) -> String {
        let deviceManager = AudioDeviceManager.shared
        let uid = inputDeviceUID ?? selectedMicrophone
        let deviceID =
            uid == AudioDevice.systemDefault.uid
            ? deviceManager.getSystemDefaultInputDevice()
            : deviceManager.getDeviceID(for: uid)
        guard let deviceID, let name = deviceManager.getDeviceName(for: deviceID) else {
            return "overlay.mic_generic".localized
        }
        return name
    }

    private func endInputDeviceOverrideIfNeeded() {
        guard activeInputDeviceOverrideUID != nil else { return }
        activeInputDeviceOverrideUID = nil
        PreferredMicrophoneCoordinator.shared.endExternalDefaultInputSession()
    }

    /// Approximate session peak in dBFS, derived from the normalized level.
    private var approximateSessionPeakDb: Int {
        Int(levelTracker.peak * 60 - 60)
    }

    /// Single failure presenter: overlay dismiss time, retry affordance, and
    /// sound all derive from the failure kind. No-speech keeps the menu bar
    /// idle and skips the error sound.
    func presentTranscriptionFailure(_ failure: TranscriptionFailure) {
        let errorState = ErrorState(failure: failure)
        if errorState.isNoSpeech {
            checkInitialState()
        } else {
            transition(to: .error(errorState), reason: "transcription-failure")
        }
        overlayManager.showError(errorState)
        if playSoundEnabled && !errorState.isNoSpeech {
            SoundManager.shared.play(.error)
        }
    }

    private func transcribeAudio(
        at audioURL: URL,
        using variant: TranscriptionEngineVariant,
        language: String
    ) async throws -> String {
        // Fail fast with a clear message if the recording is missing, empty, or corrupt.
        try AudioFileValidator.validate(audioURL)

        // A finished recording always goes through a file endpoint, so a
        // live-only variant resolves to its provider's file model here.
        let engine = variant.fileTranscriptionVariant.engine

        // R7: offline fast-fail instead of riding the request timeout. Covers
        // retry and history retranscription too; local engines are unaffected.
        if engine.requiresInternet && NetworkReachability.shared.isOffline {
            throw TranscriptionFailure(
                kind: .network, engine: engine.displayName,
                technicalDetail: "offline fast-fail before request"
            )
        }
        let transcript: String
        switch engine {
        case .mlxWhisper:
            defer { unloadMLXModelIfNotSelected() }
            // R4: after an idle unload the reload kicked off at recording
            // start may still be in flight — await it before transcribing.
            if !mlxWhisperTranscriber.isModelLoaded {
                guard let model = currentMLXWhisperModel else {
                    throw MLXWhisperError.modelNotLoaded
                }
                try await mlxWhisperTranscriber.loadModel(model)
            }
            transcript = try await mlxWhisperTranscriber.transcribe(audioURL: audioURL, language: language)
        case .deepgram:
            transcript = try await deepgramTranscriber.transcribe(audioURL: audioURL, language: language)
        case .localAIServer:
            transcript = try await localAIServerTranscriber.transcribe(audioURL: audioURL, language: language)
        case .elevenLabsScribe:
            transcript = try await elevenLabsTranscriber.transcribe(audioURL: audioURL, language: language)
        }

        // Shared anti-hallucination pass: punctuation debris, repetition
        // loops, and glossary echo from short/near-silent takes become the
        // no-speech flow instead of pasting garbage.
        switch WhisperHallucinationFilter.evaluate(
            transcript, vocabularyTerms: VocabularyManager.shared.echoDetectionTerms())
        {
        case .speech(let cleaned):
            if cleaned != transcript {
                SapoLog.recording.warning(
                    "Hallucination filter collapsed repetition loop chars=\(transcript.count, privacy: .public)->\(cleaned.count, privacy: .public)"
                )
            }
            return cleaned
        case .nonSpeech(let reason):
            throw TranscriptionFailure(
                kind: .emptyTranscription,
                engine: engine.displayName,
                technicalDetail: "hallucination filter: \(reason)"
            )
        }
    }

    private func historyEngineName(for variant: TranscriptionEngineVariant) -> String {
        switch variant {
        case .localAIServer:
            return "Local AI Server · \(LocalAIServerConfiguration.storedModel)"
        case .mlxWhisper:
            let modelName = currentMLXWhisperModel?.displayName ?? mlxWhisperTranscriber.loadedModelName
            return modelName.map { "Whisper MLX · \($0)" } ?? "Whisper MLX"
        case .deepgramNova3, .deepgramFluxLive, .elevenLabsScribeBatch, .elevenLabsScribeRealtime:
            return variant.displayName
        }
    }

    func postProcessTranscript(
        _ rawText: String,
        source: String,
        duration: TimeInterval?
    ) async -> TranscriptAIResult {
        // Live dictations honor the user's minimum-duration setting; history
        // re-runs are explicit intent and always attempt.
        let willAttemptPolish = transcriptPostProcessor.willAttemptPolish(
            rawText: rawText,
            duration: duration,
            enforceMinimumDuration: !isReprocessingHistory
        )
        if willAttemptPolish {
            // History re-runs reuse this helper but must not drive the live
            // dictation UI: suppress the busy state + overlay, keep diagnostics.
            if !isReprocessingHistory {
                transition(to: .polishing, reason: "polish-start")
                let usesLocalPolishBudget = PolishProviderConfiguration.configuredEndpointUsesLocalTimeoutBudget()
                // Same per-chunk sum the processor enforces — a chunked
                // transcript's countdown must not hit 0 mid-polish.
                overlayManager.updateState(
                    .polishing(
                        timeoutSeconds: TranscriptPostProcessor.totalPolishBudget(
                            forText: rawText,
                            duration: duration,
                            usesLocalBudget: usesLocalPolishBudget,
                            mode: PolishMode.current()
                        ),
                        compact: PolishMode.current() == .compact
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
            duration: duration,
            enforceMinimumDuration: !isReprocessingHistory
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
        let historyId = persister.lastCompletedHistoryId
        let generation = persister.dictationGeneration
        transition(to: .polishing, reason: "repolish-start")
        let usesLocalPolishBudget = PolishProviderConfiguration.configuredEndpointUsesLocalTimeoutBudget()
        overlayManager.updateState(
            .polishing(
                timeoutSeconds: TranscriptPostProcessor.totalPolishBudget(
                    forText: rawText,
                    duration: duration,
                    usesLocalBudget: usesLocalPolishBudget,
                    mode: PolishMode.current()
                ),
                compact: PolishMode.current() == .compact
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
            paste.copyToClipboard(result.finalText)
            transition(to: .idle, reason: "repolish-done")
            overlayManager.showCompleted(text: result.finalText)
            if playSoundEnabled {
                SoundManager.shared.play(.success)
            }

            // Only update the row if no newer dictation replaced it meanwhile.
            if let historyId, generation == persister.dictationGeneration {
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

        // A graceful quit mid-transcription resolves the pre-persisted row
        // right away instead of leaving it for the next launch sweep.
        if let active = activeBatchTranscription, let historyId = active.historyId {
            historyManager.markTranscriptionFailed(
                id: historyId,
                failureCode: TranscriptionHistoryManager.interruptedTranscriptionFailureCode
            )
            active.task.cancel()
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
        let variant = sessionVariant
        let engine = variant.engine
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
        activeSessionVariant = nil
        captureCoordinator.endActiveCapture()
        AutoDuckingManager.shared.restore()
        overlayManager.updateAudioLevel(0)

        if let interrupted {
            let outcome = persister.persistAbortedCapture(
                audioURL: interrupted.audioURL,
                duration: interrupted.duration,
                engine: engine,
                engineName: historyEngineName(for: variant),
                language: selectedLanguage,
                failureKind: failureKind,
                storeRetryState: storeRetryState
            )
            // Every preserved take becomes the "continue previous dictation"
            // offer for the next recording (Esc, sleep, device death alike).
            if let historyId = outcome.historyId, let offerURL = outcome.audioURL {
                resumableStore.offer(
                    ResumableDictation(
                        historyId: historyId,
                        audioURL: offerURL,
                        duration: interrupted.duration,
                        capturedAt: Date()
                    ))
            }
            SapoLog.lifecycle.info(
                "Recording aborted reason=\(reasonLog, privacy: .public) durationSec=\(Int(interrupted.duration), privacy: .public)"
            )
        } else if !storeRetryState {
            persister.clearRetryState()
        }

        return (true, interrupted != nil)
    }

    /// Re-validates the pieces that go stale across sleep cycles: the hotkey
    /// event tap and the audio device/preflight caches.
    func handleSystemDidWake() {
        SapoLog.lifecycle.info("System did wake \(self.diagnosticContext(), privacy: .public)")
        hotkeyManager.assertHotkeyAlive(reason: "wake")
        PreferredMicrophoneCoordinator.shared.requestReconciliation(reason: "wake")
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

    /// Si el boton de grabar esta habilitado. A primary that is merely not
    /// ready no longer disables it: the backup takes the dictation from the
    /// start, so refusing here would grey out a button that would have worked.
    var canRecord: Bool {
        func canRecord(_ sessions: EngineSessions) -> Bool {
            sessions.canRecord(
                hasActiveTranscriptionSession: activeTranscriptionSessionID != nil,
                appIsBusyProcessing: appState.isBusyProcessing
            )
        }

        let primary = engineSessions(for: currentEngine)
        if canRecord(primary) { return true }
        guard !primary.isBusy, let backup = fallbackVariant, isBackupEngineUsable(backup) else {
            return false
        }
        return canRecord(engineSessions(for: backup.engine))
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
    /// The AI result shapes the toast: compact shows the trim ratio, and a
    /// polish that shipped raw (guard rejection / provider failure) says so
    /// with the error sound instead of silently passing as polished.
    func deliverTranscription(_ aiResult: TranscriptAIResult, perf: DictationPerfTimeline?) {
        let finalText = aiResult.finalText
        let outcome = Self.copiedOutcome(for: aiResult)
        persister.beginNewDictationDelivery()
        lastTranscription = finalText
        paste.copyToClipboard(finalText)
        overlayManager.showCopied(text: finalText, outcome: outcome)

        if autoPasteEnabled {
            paste.simulatePaste { perf?.markPasteDone() }
        } else {
            perf?.markPasteDone(skipped: true)
        }

        transition(to: .idle, reason: "delivered")
        if playSoundEnabled {
            SoundManager.shared.play(outcome == .aiSkipped ? .error : .success)
        }
    }

    private static func copiedOutcome(for aiResult: TranscriptAIResult) -> CopiedOutcome {
        switch aiResult.status {
        case .applied where aiResult.mode == PolishMode.compact.historyModeIdentifier:
            let rawCount = max(aiResult.rawText.count, 1)
            let reduced = max(0, rawCount - aiResult.finalText.count)
            return .compacted(percentReduced: Int((Double(reduced) / Double(rawCount) * 100).rounded()))
        case .failed, .rejectedFidelity:
            return .aiSkipped
        case .applied, .none, .skippedShort, .skippedDuration:
            return .standard
        }
    }

    func persistCompletedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?,
        target: HistoryPersistenceTarget
    ) {
        persister.persistCompleted(
            audioURL: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: aiResult,
            perf: perf,
            target: target
        )
    }

    func persistFailedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        failure: TranscriptionFailure,
        target: HistoryPersistenceTarget
    ) {
        persister.persistFailed(
            audioURL: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            failure: failure,
            target: target
        )
    }

    func logTranscriptionSnapshot(reason: String, extra: String) {
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: reason,
            context: diagnosticContext(extra: extra),
            force: true
        )
    }
}
