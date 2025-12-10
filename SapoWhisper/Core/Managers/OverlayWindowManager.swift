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

    // MARK: - Private Properties

    private var overlayWindow: RecordingOverlayWindow?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var isAnimating = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Muestra la ventana de overlay con animacion
    func show() {
        guard overlayWindow == nil else {
            // Ya esta visible, solo actualizar estado
            return
        }

        // Crear la vista SwiftUI
        let overlayView = RecordingOverlayView(manager: self)
        hostingView = NSHostingView(rootView: overlayView)

        guard let hostingView = hostingView else { return }

        // Configurar hosting view para transparencia total
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        // Crear contenedor transparente
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 280))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false
        containerView.addSubview(hostingView)
        hostingView.frame = containerView.bounds

        // Crear la ventana
        overlayWindow = RecordingOverlayWindow(contentView: containerView)

        guard let window = overlayWindow else { return }

        // Preparar animacion de entrada
        window.alphaValue = 0
        window.orderFront(nil)

        // Animacion de aparicion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
    }

    /// Oculta la ventana de overlay con animacion
    func hide() {
        guard let window = overlayWindow else { return }
        guard !isAnimating else { return }

        isAnimating = true

        // Animacion de salida
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayWindow?.orderOut(nil)
                self.overlayWindow = nil
                self.hostingView = nil
                self.state = .hidden
                self.isAnimating = false
            }
        })
    }

    /// Actualiza el estado del overlay
    func updateState(_ newState: RecordingOverlayState) {
        // Si se oculta, usar hide() para la animacion
        if case .hidden = newState {
            hide()
            return
        }

        // Si no hay ventana visible, mostrarla
        if overlayWindow == nil && newState.isVisible {
            show()
        }

        state = newState
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
        state = .completed(text: text)

        // Auto-ocultar despues del delay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .completed = self.state {
                self.hide()
            }
        }
    }

    /// Muestra un error
    func showError(message: String, autoDismissAfter delay: TimeInterval = 3.0) {
        state = .error(message: message)

        // Auto-ocultar despues del delay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if case .error = self.state {
                self.hide()
            }
        }
    }
}
