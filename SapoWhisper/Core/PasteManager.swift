//
//  PasteManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import AppKit

/// Maneja el portapapeles y auto-paste
class PasteManager {
    
    /// Copia texto al portapapeles del sistema
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("📋 Texto copiado al portapapeles: \(text.prefix(50))...")
    }
    
    /// Simula Cmd+V para pegar automáticamente
    static func simulatePaste() {
        // Crear evento de tecla Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key down de Command
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        
        // Key down de V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        
        // Key up de V
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        
        // Key up de Command
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        
        // Ejecutar eventos
        let location = CGEventTapLocation.cghidEventTap
        vDown?.post(tap: location)
        vUp?.post(tap: location)
        
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
