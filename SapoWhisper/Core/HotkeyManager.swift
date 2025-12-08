//
//  HotkeyManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Cocoa
import Carbon
import Combine

/// Maneja los hotkeys globales de la aplicación
class HotkeyManager: ObservableObject {
    
    static let shared = HotkeyManager()
    
    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyCallback: (() -> Void)?
    
    // Hotkey por defecto: Option + Space
    @Published var currentKeyCode: UInt32 = UInt32(kVK_Space)
    @Published var currentModifiers: UInt32 = UInt32(optionKey)
    
    private init() {}
    
    /// Registra el hotkey global
    func registerHotkey(callback: @escaping () -> Void) {
        self.hotkeyCallback = callback
        
        // Desregistrar hotkey anterior si existe
        unregisterHotkey()
        
        // Configurar el event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.hotkeyCallback?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        
        if status != noErr {
            print("❌ Error instalando event handler: \(status)")
            return
        }
        
        // Registrar el hotkey
        var hotkeyID = EventHotKeyID(signature: OSType(0x53575049), id: 1) // "SWPI"
        
        let registerStatus = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        
        if registerStatus != noErr {
            print("❌ Error registrando hotkey: \(registerStatus)")
        } else {
            print("✅ Hotkey registrado: Option + Space")
        }
    }
    
    /// Desregistra el hotkey actual
    func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    
    /// Cambia el hotkey
    func updateHotkey(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        currentKeyCode = keyCode
        currentModifiers = modifiers
        registerHotkey(callback: callback)
    }
    
    /// Texto descriptivo del hotkey actual
    var hotkeyDescription: String {
        var parts: [String] = []
        
        if currentModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if currentModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if currentModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if currentModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        
        // Agregar la tecla
        switch Int(currentKeyCode) {
        case kVK_Space: parts.append("Space")
        case kVK_Return: parts.append("Return")
        case kVK_ANSI_S: parts.append("S")
        default: parts.append("Key\(currentKeyCode)")
        }
        
        return parts.joined(separator: " + ")
    }
    
    deinit {
        unregisterHotkey()
    }
}
