//
//  PasteManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import AppKit
import Carbon

/// Maneja el portapapeles y auto-paste
class PasteManager {

    /// Guarda la app activa antes de grabar para volver a ella después
    private static var previousApp: NSRunningApplication?

    /// Guarda la app activa actual
    static func savePreviousApp() {
        previousApp = NSWorkspace.shared.frontmostApplication
        print("💾 App guardada: \(previousApp?.localizedName ?? "ninguna")")
    }

    /// Copia texto al portapapeles del sistema
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("📋 Texto copiado al portapapeles: \(text.prefix(50))...")
    }

    /// Simula Cmd+V para pegar automáticamente
    static func simulatePaste() {
        // Primero activar la app anterior donde el usuario estaba escribiendo
        if let app = previousApp {
            app.activate(options: [])
            print("🔄 Activando app: \(app.localizedName ?? "desconocida")")
        }

        // Pequeño delay para que la app se active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            performPaste()
        }
    }

    private static func performPaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Crear eventos Cmd+V
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            print("❌ Error creando eventos de teclado")
            return
        }

        // Agregar modificador Command
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // Ejecutar eventos
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)

        print("⌨️ Auto-paste ejecutado")
    }

    /// Copia texto y lo pega automáticamente
    static func copyAndPaste(_ text: String) {
        copyToClipboard(text)

        // Pequeño delay para asegurar que el clipboard esté listo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            simulatePaste()
        }
    }
}
