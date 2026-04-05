//
//  RecordingOverlayWindow.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import AppKit
import SwiftUI

/// NSPanel personalizado para la ventana de overlay de grabacion
/// Pill horizontal posicionado en la parte inferior de la pantalla
class RecordingOverlayWindow: NSPanel {

    init(contentView: NSView, width: CGFloat = 380, height: CGFloat = 48) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configuracion de la ventana - transparencia total
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.backgroundColor = NSColor.clear
        self.isOpaque = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Permitir clicks en controles sin robar focus de la app activa
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true

        // Asignar contenido
        self.contentView = contentView
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // Posicionar abajo centrado
        positionAtBottom()
    }

    /// Posiciona la ventana centrada en la parte inferior de la pantalla
    func positionAtBottom() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = self.frame

        let x = screenFrame.midX - windowFrame.width / 2
        let y = screenFrame.minY + 60

        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Permite clicks en botones sin robar focus
    override var canBecomeKey: Bool {
        return true
    }

    /// Evita que la ventana se convierta en main window
    override var canBecomeMain: Bool {
        return false
    }
}
