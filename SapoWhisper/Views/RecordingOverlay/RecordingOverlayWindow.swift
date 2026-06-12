//
//  RecordingOverlayWindow.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import AppKit
import SwiftUI
import os

/// User-selectable screen anchor for the recording pill.
enum OverlayPosition: String, CaseIterable, Identifiable {
    case bottom
    case top
    case center

    var id: String { rawValue }

    static var configured: OverlayPosition {
        let stored = UserDefaults.standard.string(forKey: Constants.StorageKeys.overlayPosition)
        return stored.flatMap(OverlayPosition.init(rawValue:)) ?? .bottom
    }

    var displayName: String {
        switch self {
        case .bottom: return "settings.overlay_position_bottom".localized
        case .top: return "settings.overlay_position_top".localized
        case .center: return "settings.overlay_position_center".localized
        }
    }
}

/// NSPanel personalizado para la ventana de overlay de grabacion
/// Pill horizontal posicionado en la parte inferior de la pantalla
class RecordingOverlayWindow: NSPanel, NSWindowDelegate {

    init(contentView: NSView, width: CGFloat = 380, height: CGFloat = 48) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configuracion de la ventana - transparencia total
        self.level = .statusBar
        self.isMovableByWindowBackground = false
        self.backgroundColor = NSColor.clear
        self.isOpaque = false
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Permitir clicks en controles sin robar focus de la app activa
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true

        // Asignar contenido
        self.contentView = contentView
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        // Posicionar segun la preferencia del usuario
        applyConfiguredPosition()

        // Content-driven resizes (the hosting view tracks the pill's ideal
        // size) must keep the pill anchored, not pinned to a stale origin.
        self.delegate = self
    }

    func windowDidResize(_ notification: Notification) {
        applyConfiguredPosition()
    }

    /// Anchors the pill horizontally centered at the user-selected position
    /// (bottom by default, top or center as alternatives). Content morphs
    /// re-anchor on every animation frame, so only `verbose` callers (show)
    /// log the position.
    func applyConfiguredPosition(verbose: Bool = false) {
        guard let screen = targetScreen() else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = self.frame
        let margin: CGFloat = 60

        let x = screenFrame.midX - windowFrame.width / 2
        let y: CGFloat
        switch OverlayPosition.configured {
        case .bottom:
            y = screenFrame.minY + margin
        case .top:
            y = screenFrame.maxY - windowFrame.height - margin
        case .center:
            y = screenFrame.midY - windowFrame.height / 2
        }

        self.setFrameOrigin(NSPoint(x: x, y: y))
        if verbose {
            SapoLog.overlay.info("Overlay positioned origin=\(Int(x), privacy: .public),\(Int(y), privacy: .public)")
        }
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let hoveredScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return hoveredScreen
        }

        return NSScreen.main ?? NSScreen.screens.first
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
