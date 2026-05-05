//
//  HotkeyManager.swift
//  SapoWhisper
//
//

import Carbon
import Cocoa
import Combine
import OSLog
import os

/// Maneja los hotkeys globales de la aplicación
class HotkeyManager: ObservableObject {

    static let shared = HotkeyManager()

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var hotkeyCallback: (() -> Void)?

    // Hotkey por defecto: Option + Space
    @Published var currentKeyCode: UInt32
    @Published var currentModifiers: UInt32

    private init() {
        // Cargar valores guardados o usar defaults
        let savedKeyCode = UserDefaults.standard.integer(forKey: Constants.StorageKeys.hotkeyKeyCode)
        let savedModifiers = UserDefaults.standard.integer(forKey: Constants.StorageKeys.hotkeyModifiers)

        self.currentKeyCode = savedKeyCode > 0 ? UInt32(savedKeyCode) : UInt32(kVK_Space)
        self.currentModifiers = savedModifiers > 0 ? UInt32(savedModifiers) : UInt32(optionKey)
    }

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
                SapoLog.hotkey.info("Global hotkey pressed")
                manager.hotkeyCallback?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status != noErr {
            SapoLog.hotkey.error("Failed to install event handler status=\(status, privacy: .public)")
            print("❌ Error instalando event handler: \(status)")
            return
        }

        // Registrar el hotkey
        let hotkeyID = EventHotKeyID(signature: OSType(0x53575049), id: 1)  // "SWPI"

        let registerStatus = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerStatus != noErr {
            SapoLog.hotkey.error("Failed to register hotkey status=\(registerStatus, privacy: .public)")
            print("❌ Error registrando hotkey: \(registerStatus)")
        } else {
            SapoLog.hotkey.info("Global hotkey registered \(self.hotkeyDescription, privacy: .public)")
            print("✅ Hotkey registrado: \(hotkeyDescription)")
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

    /// Cambia el hotkey manteniendo el callback existente
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        currentKeyCode = keyCode
        currentModifiers = modifiers

        // Guardar en UserDefaults
        UserDefaults.standard.set(Int(keyCode), forKey: Constants.StorageKeys.hotkeyKeyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: Constants.StorageKeys.hotkeyModifiers)

        // Re-registrar con el callback existente
        if let callback = hotkeyCallback {
            registerHotkey(callback: callback)
        }
    }

    /// Cambia el hotkey con un nuevo callback
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
