//
//  OverlayWindowManager.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import AppKit
import SwiftUI
import Combine

/// Gestiona la ventana de overlay de grabacion
/// Singleton para controlar mostrar/ocultar y actualizar estados
@MainActor
class OverlayWindowManager: ObservableObject {

    static let shared = OverlayWindowManager()

    // MARK: - Published Properties

    @Published private(set) var state: RecordingOverlayState = .hidden
    @Published var audioLevel: Float = 0.0

    // MARK: - Callbacks

    /// Callback para toggle de pausa/resume (configurado por el ViewModel)
    var onPauseToggle: (() -> Void)?

    /// Callback for retry on failure
    var onRetry: (() -> Void)?

    // MARK: - Private Properties

    private var overlayWindow: RecordingOverlayWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var isAnimating = false
    private var presentationRevision: UInt = 0

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Pre-creates the overlay window so the first hotkey press only needs to show it.
    func prewarm() {
        let t0 = CFAbsoluteTimeGetCurrent()
        ensureWindow()
        overlayWindow?.orderOut(nil)
        overlayWindow?.alphaValue = 0
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("⏱️ [overlay prewarm] ready in \(String(format: "%.0f", elapsed))ms")
    }

    /// Muestra la ventana de overlay con animacion
    func show() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let reusedWindow = overlayWindow != nil
        ensureWindow()
        guard let window = overlayWindow else { return }
        presentationRevision &+= 1
        let revision = presentationRevision
        isAnimating = false

        window.positionAtBottom()
        window.contentView?.layer?.removeAllAnimations()

        // Preparar animacion de entrada
        window.alphaValue = 0
        window.orderFrontRegardless()

        // Animacion de aparicion (rapida para feedback inmediato)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        guard revision == presentationRevision else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("⏱️ [overlay show] \(reusedWindow ? "reused" : "created") in \(String(format: "%.0f", elapsed))ms")
    }

    /// Oculta la ventana de overlay con animacion
    func hide() {
        guard let window = overlayWindow else { return }

        isAnimating = true
        let revisionAtHide = presentationRevision

        // Animacion de salida
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only clean up if this is still the current window
                // (a new show() call may have replaced it already)
                guard self.overlayWindow === window, self.presentationRevision == revisionAtHide else { return }
                self.overlayWindow?.orderOut(nil)
                self.state = .hidden
                self.isAnimating = false
            }
        })
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

        let windowWidth: CGFloat = 380
        let windowHeight: CGFloat = 48

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false
        containerView.addSubview(hostingView)
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]

        overlayWindow = RecordingOverlayWindow(contentView: containerView, width: windowWidth, height: windowHeight)
        isAnimating = false
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("⏱️ [overlay build] window created in \(String(format: "%.0f", elapsed))ms")
    }

    /// Actualiza el estado del overlay
    func updateState(_ newState: RecordingOverlayState) {
        // Si se oculta, usar hide() para la animacion
        if case .hidden = newState {
            hide()
            return
        }

        state = newState

        if newState.isVisible, overlayWindow?.isVisible != true {
            show()
        }
    }

    /// Actualiza el nivel de audio (para el ecualizador)
    func updateAudioLevel(_ level: Float) {
        audioLevel = level
    }

    /// Actualiza la duracion de grabacion
    func updateRecordingDuration(_ duration: TimeInterval) {
        if case .recording = state {
            state = .recording(duration: duration)
        }
    }

    /// Muestra el estado de completado con preview del texto
    func showCompleted(text: String, autoDismissAfter delay: TimeInterval = 2.0) {
        updateState(.completed(text: text))

        // Auto-ocultar despues del delay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .completed = self.state {
                self.hide()
            }
        }
    }

    /// Shows a brief notification that a new audio device was detected
    func showDeviceDetected(deviceName: String, autoDismissAfter delay: TimeInterval = 2.5) {
        // Don't interrupt active recording/transcribing states
        switch state {
        case .recording, .transcribing, .paused:
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


    /// Muestra un error
    func showError(message: String, autoDismissAfter delay: TimeInterval = 3.0) {
        updateState(.error(message: message))

        // Auto-ocultar despues del delay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .error = self.state {
                self.hide()
            }
        }
    }
}
