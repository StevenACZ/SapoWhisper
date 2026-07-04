//
//  OverlayWindowManager.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import AppKit
import Combine
import OSLog
import SwiftUI
import os

/// Gestiona la ventana de overlay de grabacion
/// Singleton para controlar mostrar/ocultar y actualizar estados
@MainActor
class OverlayWindowManager: ObservableObject {

    static let shared = OverlayWindowManager()

    // MARK: - Published Properties

    @Published private(set) var state: RecordingOverlayState = .hidden

    /// Live "no voice?" hint while recording (NS2): set by the ViewModel when
    /// the session peak stays under the silence threshold for a few seconds.
    @Published private(set) var showsNoSpeechHint = false

    /// While recording: name of the input that has not delivered real signal
    /// yet. Bluetooth mics (AirPods) spend 1–3 s renegotiating before audio
    /// flows — the pill shows "connecting" instead of a dead flat waveform.
    /// Cleared by the first non-silent buffer, a timeout, or leaving recording.
    @Published private(set) var micConnectingName: String?
    private var micConnectingTimeoutTask: Task<Void, Never>?
    /// Give up on the connecting label after this long; the regular no-speech
    /// hint takes over for genuinely dead inputs.
    private static let micConnectingTimeout: TimeInterval = 6.0

    /// "Continue previous dictation" chip state while recording: a recent
    /// cancelled/crashed take can be prepended to this one at stop time.
    /// `nil` means no offer; set by the ViewModel when a resumable take exists.
    struct ResumeOffer: Equatable {
        let durationLabel: String
        var isActive: Bool
    }

    @Published private(set) var resumeOffer: ResumeOffer?

    /// The user toggled the resume chip (already reflected in `resumeOffer`).
    var onResumeToggled: ((Bool) -> Void)?

    let audioLevelPublisher: AnyPublisher<Float, Never>

    // MARK: - Callbacks

    /// Callback para toggle de pausa/resume (configurado por el ViewModel)
    var onPauseToggle: (() -> Void)?

    /// Callback for retry on failure
    var onRetry: (() -> Void)?

    /// The translation chip was toggled while recording (defaults already updated).
    var onQuickTranslationToggled: ((Bool) -> Void)?

    /// The translation chip was toggled on the completed pill: re-polish the
    /// last dictation with the freshly stored language default.
    var onRepolishRequested: (() -> Void)?

    // MARK: - Private Properties

    private var overlayWindow: RecordingOverlayWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var isAnimating = false
    private var presentationRevision: UInt = 0
    private var completedDismissTask: Task<Void, Never>?
    /// Last delivered transcription, reopened when the dock chip is clicked.
    private var lastCompletedText: String?
    /// Global+local mouse monitors active while the completed pill is open,
    /// so a click anywhere outside collapses it back into the dock chip.
    private var outsideClickMonitors: [Any] = []
    private let audioLevelSubject = PassthroughSubject<Float, Never>()
    private var lastAudioLevelEmitTime: CFAbsoluteTime = 0
    private var lastAudioLevelValue: Float = 0
    private var displayedRecordingSecond: Int?
    private var meterSessionStartedAt: CFAbsoluteTime?
    private var meterInputSamples = 0
    private var meterPublishedSamples = 0

    /// Detach/absorb spring for the droplet pill separating from the dock
    /// chip: slightly bouncier than the active-swap morph so the drop reads
    /// as physical.
    static let dropletAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.7)

    // MARK: - Initialization

    private init() {
        audioLevelPublisher = audioLevelSubject.eraseToAnyPublisher()
    }

    // MARK: - Public Methods

    /// Creates the overlay window and rests it as the always-visible dock
    /// chip: recording morphs out of the chip and every dismissal collapses
    /// back into it.
    func prewarm() {
        let t0 = CFAbsoluteTimeGetCurrent()
        ensureWindow()
        guard let window = overlayWindow else { return }
        state = .docked
        window.applyConfiguredPosition()
        window.alphaValue = 1
        window.orderFrontRegardless()
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        SapoLog.overlay.info("Overlay prewarmed docked in \(Int(elapsed), privacy: .public)ms")
    }

    /// Muestra la ventana de overlay con animacion
    func show() {
        let signpostState = SapoSignpost.begin(SapoSignpost.Name.hotkeyToOverlay)
        let t0 = CFAbsoluteTimeGetCurrent()
        let reusedWindow = overlayWindow != nil
        ensureWindow()
        guard let window = overlayWindow else {
            SapoSignpost.end(SapoSignpost.Name.hotkeyToOverlay, state: signpostState)
            return
        }
        presentationRevision &+= 1
        let revision = presentationRevision
        isAnimating = false

        window.applyConfiguredPosition(verbose: true)
        window.contentView?.layer?.removeAllAnimations()

        // Preparar animacion de entrada. Si la ventana sigue visible (p. ej.
        // se interrumpe un fade-out), continuar desde su alpha actual evita
        // un parpadeo a transparente.
        if !window.isVisible {
            window.alphaValue = 0
        }
        window.orderFrontRegardless()

        // Animacion de aparicion (rapida para feedback inmediato)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        guard revision == presentationRevision else {
            SapoSignpost.end(SapoSignpost.Name.hotkeyToOverlay, state: signpostState)
            return
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let reuseState = reusedWindow ? "reused" : "created"
        SapoLog.overlay.info(
            "Overlay shown state=\(reuseState, privacy: .public) elapsed=\(Int(elapsed), privacy: .public)ms"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "overlay-show",
            context: "reuse=\(reuseState) elapsedMs=\(Int(elapsed))",
            force: true
        )
        SapoSignpost.end(SapoSignpost.Name.hotkeyToOverlay, state: signpostState)
    }

    /// Collapses whatever is showing back into the idle dock chip. The window
    /// never disappears: the chip is the overlay's resting state, and hovering
    /// it reopens the last transcription.
    func hide() {
        guard overlayWindow != nil else { return }
        guard state.stateCategory != "docked" else { return }

        completedDismissTask?.cancel()
        completedDismissTask = nil
        finishMeterSession(reason: "docked")
        displayedRecordingSecond = nil
        publishAudioLevel(0, force: true)
        showsNoSpeechHint = false
        withAnimation(Self.dropletAnimation) {
            state = .docked
        }
        syncOutsideClickMonitors()
        SapoLog.overlay.info("Overlay collapsed to dock")
    }

    /// Dock chip click: toggle — reopen the last transcription when idle,
    /// collapse the open result back into the chip otherwise.
    func dockChipTapped() {
        switch state {
        case .docked:
            expandDockToLastTranscription()
        case .completed:
            hide()
        default:
            break
        }
    }

    /// Reopen the last transcription from the dock chip.
    func expandDockToLastTranscription() {
        guard case .docked = state else { return }
        guard let text = lastCompletedText, !text.isEmpty else { return }
        updateState(.completed(text: text))
        // Fallback in case the pointer leaves before the pill registers its
        // own hover; hovering the pill cancels and re-arms this.
        scheduleCompletedDismiss(after: 4.0)
    }

    // MARK: - Outside-click collapse

    /// While the completed pill is open, any click outside the overlay window
    /// collapses it back into the dock chip — closing must not require
    /// hunting the X button. Monitors exist only in that state so recording
    /// and busy states are never dismissed by stray clicks.
    private func syncOutsideClickMonitors() {
        if case .completed = state {
            installOutsideClickMonitors()
        } else {
            removeOutsideClickMonitors()
        }
    }

    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }

        // Global monitor covers clicks landing in other apps; the local one
        // covers this app's own windows (Settings, History, menu bar). Both
        // hop through a MainActor task instead of assuming the calling
        // thread, so a monitor delivered off-main can never crash.
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                Task { @MainActor in
                    OverlayWindowManager.shared.collapseIfClickLandedOutside()
                }
            })
        {
            outsideClickMonitors.append(globalMonitor)
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { event in
                // No window filter: even clicks delivered to the overlay
                // window may land on its transparent margin, and the
                // collapse check hit-tests the actual content either way.
                Task { @MainActor in
                    OverlayWindowManager.shared.collapseIfClickLandedOutside()
                }
                return event
            })
        {
            outsideClickMonitors.append(localMonitor)
        }
    }

    private func removeOutsideClickMonitors() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors.removeAll()
    }

    /// Latest window-relative frame of the visible content (pill + chip),
    /// published by the overlay view on every layout pass.
    private var activeContentFrame: CGRect = .zero

    func setActiveContentFrame(_ frame: CGRect) {
        activeContentFrame = frame
    }

    /// Pure geometry for the outside-click decision, extracted for tests.
    /// An empty content frame (no layout yet) never collapses.
    nonisolated static func clickLandsOutsideContent(
        contentFrame: CGRect,
        clickPoint: CGPoint,
        margin: CGFloat = 10
    ) -> Bool {
        guard !contentFrame.isEmpty else { return false }
        return !contentFrame.insetBy(dx: -margin, dy: -margin).contains(clickPoint)
    }

    private func collapseIfClickLandedOutside() {
        guard case .completed = state else { return }
        guard let window = overlayWindow, let contentView = window.contentView else { return }

        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            hide()
            return
        }

        // Inside the window rect: the fixed 640×440 surface is mostly
        // transparent margin, so compare against the measured content frame —
        // NSHostingView.hitTest can report hits on the empty margin, which
        // made "click outside the pill" only work outside the whole surface.
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        if !activeContentFrame.isEmpty {
            if Self.clickLandsOutsideContent(contentFrame: activeContentFrame, clickPoint: viewPoint) {
                hide()
            }
            return
        }
        if contentView.hitTest(viewPoint) == nil {
            hide()
        }
    }

    // MARK: - Private Methods

    private func ensureWindow() {
        if overlayWindow != nil { return }

        let t0 = CFAbsoluteTimeGetCurrent()

        let overlayView = RecordingOverlayView(manager: self)
        hostingView = NSHostingView(rootView: overlayView)

        guard let hostingView else { return }

        // The window is a fixed-size transparent surface, so the hosting
        // view must not impose content-driven min/max window constraints.
        // With the default sizing options and a greedy root view, AppKit
        // queries sizeThatFits during its constraints pass, the animating
        // view graph invalidates mid-query, and the re-entrant update throws
        // NSInternalInconsistencyException — a hard crash.
        hostingView.sizingOptions = []

        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        overlayWindow = RecordingOverlayWindow(contentView: hostingView)
        isAnimating = false
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        SapoLog.overlay.info("Overlay window created in \(Int(elapsed), privacy: .public)ms")
    }

    /// Actualiza el estado del overlay
    func updateState(_ newState: RecordingOverlayState) {
        // Leaving the completed state through any path invalidates its
        // pending auto-dismiss so it cannot hide the next state.
        if case .completed = newState {
        } else {
            completedDismissTask?.cancel()
            completedDismissTask = nil
        }

        // Si se oculta, usar hide() para la animacion
        if case .hidden = newState {
            hide()
            return
        }

        if case .recording = state,
            case .recording = newState
        {
            // Still recording; duration-only updates should not reset the meter session.
        } else if case .recording = state {
            finishMeterSession(reason: newState.stateCategory)
        }

        updateDisplayedSecond(for: newState)
        if state.isVisible {
            // Leaving the dock plays the bouncier droplet detach; swaps
            // between active pills morph with the calmer spring while the
            // pill view sequences the content crossfade on top of it.
            let leavingDock = state.stateCategory == "docked"
            withAnimation(leavingDock ? Self.dropletAnimation : .spring(response: 0.35, dampingFraction: 0.8)) {
                state = newState
            }
        } else {
            // Coming from hidden: lay out the pill at its final size with no
            // animation; the window fade covers the appearance.
            state = newState
        }
        syncOutsideClickMonitors()
        if case .recording = newState {
        } else {
            showsNoSpeechHint = false
            setMicConnecting(deviceName: nil)
            resumeOffer = nil
        }
        SapoLog.overlay.info("Overlay state changed to \(newState.stateCategory, privacy: .public)")

        if case .recording = newState {
            beginMeterSession()
            publishAudioLevel(0, force: true)
        }

        if shouldShowOverlay(for: newState) {
            show()
        }
    }

    /// Actualiza el nivel de audio (para el ecualizador)
    func updateAudioLevel(_ level: Float) {
        if meterSessionStartedAt != nil {
            meterInputSamples += 1
        }
        publishAudioLevel(level)
    }

    /// Actualiza la duracion de grabacion
    func updateRecordingDuration(_ duration: TimeInterval) {
        if case .recording = state {
            let displaySecond = max(0, Int(duration))
            guard displayedRecordingSecond != displaySecond else { return }
            displayedRecordingSecond = displaySecond
            state = .recording(duration: TimeInterval(displaySecond))
        }
    }

    /// Muestra el estado de completado con el texto final y las acciones de
    /// re-polish. Hovering the pill pauses the auto-dismiss so the user can
    /// read, copy, or re-polish; leaving re-arms a short countdown.
    func showCompleted(text: String, autoDismissAfter delay: TimeInterval = 5.0) {
        lastCompletedText = text
        updateState(.completed(text: text))
        scheduleCompletedDismiss(after: delay)
    }

    /// Pauses/resumes the completed pill's auto-dismiss while hovered.
    func setCompletedHover(_ hovering: Bool) {
        guard case .completed = state else { return }
        if hovering {
            completedDismissTask?.cancel()
            completedDismissTask = nil
        } else {
            scheduleCompletedDismiss(after: 2.0)
        }
    }

    private func scheduleCompletedDismiss(after delay: TimeInterval) {
        completedDismissTask?.cancel()
        completedDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if case .completed = self.state {
                self.hide()
            }
        }
    }

    /// Brief confirmation after an Esc cancel: the audio was preserved in
    /// History, so the dictation is recoverable — not lost.
    func showCancelled(autoDismissAfter delay: TimeInterval = 2.5) {
        updateState(.cancelled)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .cancelled = self.state {
                self.hide()
            }
        }
    }

    /// Shows a device-route event, morphing between phases in place: the
    /// "connecting" pill upgrades to "ready" without collapsing back to the
    /// dock, so the switch reads as one continuous story.
    func showDeviceChange(_ announcement: DeviceChangeAnnouncement) {
        // Don't interrupt active recording/transcribing states
        switch state {
        case .recording, .transcribing, .polishing, .paused:
            return
        default:
            break
        }

        updateState(.deviceChange(announcement))

        // Connecting waits generously for its "ready" upgrade; terminal
        // phases dismiss on their own.
        let delay: TimeInterval
        switch announcement.phase {
        case .connecting: delay = 5.0
        case .ready: delay = 2.5
        case .fallback: delay = 4.0
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .deviceChange(let current) = self.state, current == announcement {
                self.hide()
            }
        }
    }

    /// Arms (or clears) the "continue previous dictation" chip for the
    /// current recording session. The chip starts inactive; the user opts in.
    func setResumeOffer(durationLabel: String?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            resumeOffer = durationLabel.map { ResumeOffer(durationLabel: $0, isActive: false) }
        }
    }

    /// Chip tap: flip the opt-in and tell the ViewModel.
    func toggleResumeOffer() {
        guard var offer = resumeOffer else { return }
        offer.isActive.toggle()
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            resumeOffer = offer
        }
        onResumeToggled?(offer.isActive)
    }

    /// Toggles the "connecting <mic>" phase of the recording pill. Passing a
    /// name arms a timeout that clears the label if signal never arrives.
    func setMicConnecting(deviceName: String?) {
        guard micConnectingName != deviceName else { return }

        micConnectingTimeoutTask?.cancel()
        micConnectingTimeoutTask = nil

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            micConnectingName = deviceName
        }

        if deviceName != nil {
            micConnectingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.micConnectingTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.setMicConnecting(deviceName: nil)
            }
        }
    }

    /// Muestra un error. `isRetryable` controla si se ofrece el boton de reintento.
    func showError(
        message: String,
        isRetryable: Bool = true,
        autoDismissAfter delay: TimeInterval = 5.0
    ) {
        updateState(.error(message: message, isRetryable: isRetryable))

        // Auto-ocultar despues del delay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .error = self.state {
                self.hide()
            }
        }
    }

    /// Kind-aware error presentation: no-speech dismisses fast with no retry
    /// affordance; everything else keeps the standard 5s + retry behavior.
    func showError(_ errorState: ErrorState) {
        showError(
            message: errorState.message,
            isRetryable: errorState.isNoSpeech ? false : errorState.isRetryable,
            autoDismissAfter: errorState.isNoSpeech ? 1.8 : 5.0
        )
    }

    /// Toggles the live "no voice?" pill while recording.
    func setNoSpeechHint(_ shows: Bool) {
        guard showsNoSpeechHint != shows else { return }
        if shows {
            guard case .recording = state else { return }
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showsNoSpeechHint = shows
        }
        SapoLog.overlay.info("Overlay no-speech hint \(shows ? "shown" : "cleared", privacy: .public)")
    }

    private func updateDisplayedSecond(for state: RecordingOverlayState) {
        switch state {
        case .recording(let duration):
            displayedRecordingSecond = max(0, Int(duration))
        default:
            displayedRecordingSecond = nil
        }
    }

    private func shouldShowOverlay(for state: RecordingOverlayState) -> Bool {
        guard state.isVisible else { return false }
        guard let overlayWindow else { return true }
        return overlayWindow.isVisible != true || isAnimating || overlayWindow.alphaValue < 0.99
    }

    private func publishAudioLevel(_ level: Float, force: Bool = false) {
        let clampedLevel = max(0, min(1, level))
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastAudioLevelEmitTime
        let changedEnough = abs(clampedLevel - lastAudioLevelValue) >= 0.08

        guard force || elapsed >= (1.0 / 30.0) || changedEnough else { return }

        lastAudioLevelEmitTime = now
        lastAudioLevelValue = clampedLevel
        if meterSessionStartedAt != nil {
            meterPublishedSamples += 1
        }
        audioLevelSubject.send(clampedLevel)
    }

    private func beginMeterSession() {
        guard meterSessionStartedAt == nil else { return }
        meterSessionStartedAt = CFAbsoluteTimeGetCurrent()
        meterInputSamples = 0
        meterPublishedSamples = 0
        SapoLog.overlay.info("Overlay meter session started")
    }

    private func finishMeterSession(reason: String) {
        guard let startedAt = meterSessionStartedAt else { return }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        SapoLog.overlay.info(
            "Overlay meter session finished reason=\(reason, privacy: .public) elapsed=\(elapsed, privacy: .public)ms received=\(self.meterInputSamples, privacy: .public) rendered=\(self.meterPublishedSamples, privacy: .public)"
        )

        meterSessionStartedAt = nil
        meterInputSamples = 0
        meterPublishedSamples = 0
    }
}
