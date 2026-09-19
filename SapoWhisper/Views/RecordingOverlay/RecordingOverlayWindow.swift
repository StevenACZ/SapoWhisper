//
//  RecordingOverlayWindow.swift
//  SapoWhisper
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
        let stored = AppPreferences.defaults.string(forKey: Constants.StorageKeys.overlayPosition)
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

    /// Fixed transparent surface large enough for every pill state (widest
    /// completed transcript + glow). The window must NEVER resize: resizing
    /// it during a SwiftUI transaction animation makes NSHostingView animate
    /// the window frame from inside the display cycle, which throws
    /// NSInternalInconsistencyException and crashes. Empty surface pixels are
    /// fully transparent, so clicks there fall through to the app behind.
    static let surfaceSize = NSSize(width: 640, height: 440)

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.surfaceSize),
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

        // The dock chip keeps this window on screen forever, so a resolution
        // or display change must re-anchor it; AppKit preserves the old
        // origin, which leaves the chip off-centre on the new geometry.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        applyConfiguredPosition(verbose: true, preferring: screen)
    }

    func windowDidResize(_ notification: Notification) {
        applyConfiguredPosition()
    }

    /// Anchors the pill horizontally centered at the user-selected position
    /// (bottom by default, top or center as alternatives). Content morphs
    /// re-anchor on every animation frame, so only `verbose` callers (show)
    /// log the position.
    func applyConfiguredPosition(verbose: Bool = false, preferring preferredScreen: NSScreen? = nil) {
        guard let screen = preferredScreen ?? targetScreen() else { return }

        let screenFrame = screen.visibleFrame

        // Fit the fixed surface on small screens; on normal displays this
        // never changes the size (the whole point is a constant frame).
        let fitted = NSSize(
            width: min(Self.surfaceSize.width, screenFrame.width - 12),
            height: min(Self.surfaceSize.height, screenFrame.height - 12)
        )
        if abs(frame.width - fitted.width) > 0.5 || abs(frame.height - fitted.height) > 0.5 {
            setContentSize(fitted)
        }

        // The dock chip is the permanent fixture hugging the screen edge, so
        // the window always anchors tight; active pills float above the chip
        // via the content layout, not via a window margin.
        let origin = Self.anchoredOrigin(
            in: screenFrame,
            windowSize: self.frame.size,
            position: OverlayPosition.configured
        )
        self.setFrameOrigin(origin)
        if verbose {
            SapoLog.overlay.info(
                "Overlay positioned origin=\(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public)"
            )
        }
    }

    static func anchoredOrigin(in screenFrame: NSRect, windowSize: NSSize, position: OverlayPosition) -> NSPoint {
        let margin: CGFloat = 6
        let x = screenFrame.midX - windowSize.width / 2
        var y: CGFloat
        switch position {
        case .bottom:
            y = screenFrame.minY + margin
        case .top:
            y = screenFrame.maxY - windowSize.height - margin
        case .center:
            y = screenFrame.midY - windowSize.height / 2
        }

        let minY = screenFrame.minY + margin
        let maxY = max(minY, screenFrame.maxY - windowSize.height - margin)
        y = min(max(y, minY), maxY)
        return NSPoint(x: x, y: y)
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
