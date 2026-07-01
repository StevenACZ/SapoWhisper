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

    /// True while the window fade-out runs, so the pill content can recede
    /// (slight scale-down) together with the fade.
    @Published private(set) var isDismissing = false

    /// True while the active dictation is a clipboard-edit session: the pill
    /// shows the edit label and hides the mode chips.
    @Published var isEditSession = false

    let audioLevelPublisher: AnyPublisher<Float, Never>

    // MARK: - Callbacks

    /// Callback para toggle de pausa/resume (configurado por el ViewModel)
    var onPauseToggle: (() -> Void)?

    /// Callback for retry on failure
    var onRetry: (() -> Void)?

    /// A mode chip was tapped while recording (defaults already updated).
    var onQuickModeSelected: ((String) -> Void)?

    /// The translation chip was toggled while recording (defaults already updated).
    var onQuickTranslationToggled: ((Bool) -> Void)?

    /// A chip was tapped on the completed pill: re-polish the last dictation
    /// with the freshly stored mode/language defaults.
    var onRepolishRequested: (() -> Void)?

    /// Mic button on the completed pill: dictate an instruction applied to
    /// the shown text (iterate until the text is right).
    var onVoiceEditRequested: (() -> Void)?

    // MARK: - Private Properties

    private var overlayWindow: RecordingOverlayWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var isAnimating = false
    private var presentationRevision: UInt = 0
    private var sizeSettleTask: Task<Void, Never>?
    private var completedDismissTask: Task<Void, Never>?
    /// Last delivered transcription, reopened when the dock chip is clicked.
    private var lastCompletedText: String?
    private let audioLevelSubject = PassthroughSubject<Float, Never>()
    private var lastAudioLevelEmitTime: CFAbsoluteTime = 0
    private var lastAudioLevelValue: Float = 0
    private var displayedRecordingSecond: Int?
    private var meterSessionStartedAt: CFAbsoluteTime?
    private var meterInputSamples = 0
    private var meterPublishedSamples = 0

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
        window.isDockAnchored = true
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
        isDismissing = false

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
        overlayWindow?.isDockAnchored = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            state = .docked
        }
        SapoLog.overlay.info("Overlay collapsed to dock")
    }

    /// Dock chip click: reopen the last transcription.
    func expandDockToLastTranscription() {
        guard case .docked = state else { return }
        guard let text = lastCompletedText, !text.isEmpty else { return }
        updateState(.completed(text: text))
        // Fallback in case the pointer leaves before the pill registers its
        // own hover; hovering the pill cancels and re-arms this.
        scheduleCompletedDismiss(after: 4.0)
    }

    // MARK: - Private Methods

    private func ensureWindow() {
        if overlayWindow != nil { return }

        let t0 = CFAbsoluteTimeGetCurrent()

        let overlayView = RecordingOverlayView(manager: self)
        hostingView = NSHostingView(rootView: overlayView)

        guard let hostingView else { return }

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
        isDismissing = false
        overlayWindow?.isDockAnchored = newState.stateCategory == "docked"
        if state.isVisible {
            // Visible-to-visible swaps morph the capsule with a spring; the
            // pill view sequences the content crossfade on top of it.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                state = newState
            }
        } else {
            // Coming from hidden: lay out the pill at its final size with no
            // animation; the view's entrance pop covers the appearance.
            state = newState
        }
        if case .recording = newState {
        } else {
            showsNoSpeechHint = false
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

    /// Resizes the panel to the pill's measured size (reported by the SwiftUI
    /// root) so long error messages grow the window instead of clipping at a
    /// fixed frame; the window delegate re-anchors after every resize.
    ///
    /// Growth applies immediately (a window smaller than its content clips
    /// the pill and its shadow mid-animation); shrinking waits until the size
    /// reports settle — the window is transparent, so holding the larger
    /// frame during the morph is invisible and avoids any hard cut.
    func updateWindowSize(to size: CGSize) {
        guard let window = overlayWindow else { return }
        let target = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard target.width > 1, target.height > 1 else { return }

        let current = window.frame.size
        let envelope = NSSize(
            width: max(current.width, target.width),
            height: max(current.height, target.height)
        )
        if abs(envelope.width - current.width) > 0.5 || abs(envelope.height - current.height) > 0.5 {
            window.setContentSize(envelope)
        }

        scheduleSizeSettle(to: target)
    }

    /// Trims the window down to the final reported size once the layout
    /// animation stops emitting new sizes, and logs the settled frame once
    /// (instead of one log per animation frame).
    private func scheduleSizeSettle(to target: NSSize) {
        sizeSettleTask?.cancel()
        sizeSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, let window = self.overlayWindow else { return }
            if abs(window.frame.width - target.width) > 0.5 || abs(window.frame.height - target.height) > 0.5 {
                window.setContentSize(target)
            }
            SapoLog.overlay.info(
                "Overlay size settled \(Int(target.width), privacy: .public)x\(Int(target.height), privacy: .public)"
            )
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

    /// Shows a brief notification that a new audio device was detected
    func showDeviceDetected(deviceName: String, autoDismissAfter delay: TimeInterval = 2.5) {
        // Don't interrupt active recording/transcribing states
        switch state {
        case .recording, .transcribing, .polishing, .paused:
            return
        default:
            break
        }

        updateState(.deviceDetected(deviceName: deviceName))

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .deviceDetected = self.state {
                self.hide()
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
