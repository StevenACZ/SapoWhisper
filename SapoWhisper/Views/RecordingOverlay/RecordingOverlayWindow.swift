//
//  RecordingOverlayWindow.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import AppKit
import SwiftUI

/// NSPanel personalizado para la ventana de overlay de grabacion
/// Configurado para no robar focus y mantenerse flotante
class RecordingOverlayWindow: NSPanel {

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configuracion de la ventana - transparencia total
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.backgroundColor = NSColor.clear
        self.isOpaque = false
        self.hasShadow = false  // Sin sombra de ventana del sistema
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // No activar la ventana (no roba focus)
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true

        // Asignar contenido
        self.contentView = contentView
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // Centrar en pantalla
        centerOnScreen()
    }

    /// Centra la ventana en la pantalla principal
    func centerOnScreen() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = self.frame

        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.midY - windowFrame.height / 2

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Evita que la ventana se convierta en key window
    override var canBecomeKey: Bool {
        return false
    }

    /// Evita que la ventana se convierta en main window
    override var canBecomeMain: Bool {
        return false
    }
}
