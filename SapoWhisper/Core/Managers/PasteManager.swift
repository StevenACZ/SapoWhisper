//
//  PasteManager.swift
//  SapoWhisper
//
//

import AppKit
import Carbon
import os

/// Maneja el portapapeles y auto-paste
class PasteManager {

    private static let initialActivationDelay: TimeInterval = 0.03
    private static let activationPollInterval: TimeInterval = 0.02
    private static let activationTimeout: TimeInterval = 0.18

    /// Guarda la app activa antes de grabar para volver a ella después
    private static var previousApp: NSRunningApplication?
    private static var lastPasteTriggerTime: CFAbsoluteTime = 0

    /// Guarda la app activa actual
    static func savePreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        SapoLog.menuBar.info(
            "Saved previous app name=\(self.previousApp?.localizedName ?? "none", privacy: .public)"
        )
    }

    /// Copia texto al portapapeles del sistema
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        SapoLog.menuBar.info("Clipboard updated chars=\(text.count, privacy: .public)")
    }

    /// Simula Cmd+V para pegar automáticamente
    static func simulatePaste() {
        let t0 = CFAbsoluteTimeGetCurrent()
        lastPasteTriggerTime = t0
        let targetApp = previousApp

        // Primero activar la app anterior donde el usuario estaba escribiendo
        if let app = targetApp {
            app.activate(options: [])
            SapoLog.menuBar.info(
                "Reactivating previous app name=\(app.localizedName ?? "unknown", privacy: .public)"
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialActivationDelay) {
            attemptPaste(for: targetApp, startedAt: t0)
        }
    }

    private static func attemptPaste(for targetApp: NSRunningApplication?, startedAt startTime: CFAbsoluteTime) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let isReadyToPaste: Bool

        if let targetApp {
            isReadyToPaste = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier
        } else {
            isReadyToPaste = true
        }

        if isReadyToPaste || elapsed >= activationTimeout {
            let activationDelay = Int(elapsed * 1000)
            SapoLog.menuBar.info("Paste activation waitMs=\(activationDelay, privacy: .public)")
            performPaste()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + activationPollInterval) {
            attemptPaste(for: targetApp, startedAt: startTime)
        }
    }

    private static func performPaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Crear eventos Cmd+V
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            SapoLog.menuBar.error("Paste keyboard event creation failed")
            return
        }

        // Agregar modificador Command
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Ejecutar eventos
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        let totalElapsed = Int((CFAbsoluteTimeGetCurrent() - lastPasteTriggerTime) * 1000)
        SapoLog.menuBar.info(
            "Auto-paste done totalMs=\(totalElapsed, privacy: .public)"
        )
    }

    /// Copia texto y lo pega automáticamente
    static func copyAndPaste(_ text: String) {
        copyToClipboard(text)
        DispatchQueue.main.async {
            simulatePaste()
        }
    }
}
