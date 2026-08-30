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

    private static let activationFallbackDelay: TimeInterval = 0.15

    /// Guarda la app activa antes de grabar para volver a ella después
    private static var previousApp: NSRunningApplication?
    private static var lastPasteTriggerTime: CFAbsoluteTime = 0
    private static var activationObserver: NSObjectProtocol?
    private static var activationFallbackWorkItem: DispatchWorkItem?

    /// Guarda la app activa actual
    static func savePreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        SapoLog.menuBar.info("Saved previous app available=\(self.previousApp != nil, privacy: .public)")
    }

    /// Copia texto al portapapeles del sistema
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // nspasteboard.org convention: dictated speech is sensitive by
        // default, so mark it concealed — clipboard managers skip it and it
        // stays out of their synced histories.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        SapoLog.menuBar.info("Clipboard updated chars=\(text.count, privacy: .public)")
    }

    /// Simula Cmd+V para pegar automáticamente.
    /// Activa la app anterior y pega en cuanto el sistema notifica la
    /// activación (fallback fijo si la notificación no llega), en vez de
    /// esperar con polling.
    @MainActor
    static func simulatePaste(onPasted: (@MainActor () -> Void)? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        lastPasteTriggerTime = t0
        cancelPendingActivationWait()

        guard let targetApp = previousApp else {
            performPaste()
            onPasted?()
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier {
            SapoLog.menuBar.info("Paste target already frontmost waitMs=0")
            performPaste()
            onPasted?()
            return
        }

        targetApp.activate(options: [])
        SapoLog.menuBar.info("Reactivating previous app")

        // Both triggers (workspace notification with queue .main, and the
        // main-queue fallback) deliver on the main thread.
        let pasteOnce: @Sendable (String) -> Void = { trigger in
            MainActor.assumeIsolated {
                cancelPendingActivationWait()
                let waitMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                SapoLog.menuBar.info(
                    "Paste activation trigger=\(trigger, privacy: .public) waitMs=\(waitMs, privacy: .public)"
                )
                performPaste()
                onPasted?()
            }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier == targetApp.processIdentifier else { return }
            pasteOnce("notification")
        }

        let fallback = DispatchWorkItem {
            pasteOnce("fallback")
        }
        activationFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + activationFallbackDelay, execute: fallback)
    }

    @MainActor
    private static func cancelPendingActivationWait() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        activationFallbackWorkItem?.cancel()
        activationFallbackWorkItem = nil
    }

    @MainActor
    private static func performPaste() {
        // When another app holds Secure Keyboard Entry (password fields, some
        // terminals), a synthetic Cmd+V is swallowed silently. Skip it and
        // leave the text on the clipboard so the user can paste manually.
        if IsSecureEventInputEnabled() {
            SapoLog.menuBar.warning(
                "Auto-paste skipped reason=secure-input-active; text left on clipboard"
            )
            return
        }

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
        Task { @MainActor in
            simulatePaste()
        }
    }
}
