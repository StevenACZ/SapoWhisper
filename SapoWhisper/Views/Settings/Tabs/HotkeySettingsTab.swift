//
//  HotkeySettingsTab.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI
import Carbon

/// Tab de configuración del atajo de teclado global
struct HotkeySettingsTab: View {
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) private var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) private var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    
    @State private var isRecordingHotkey = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hotkeyCard
                presetsCard
                permissionsCard
            }
            .padding()
        }
    }
    
    // MARK: - Hotkey Card
    
    private var hotkeyCard: some View {
        SettingsCard(icon: "keyboard", title: "settings.hotkeys".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HotkeyRecorderView(
                    keyCode: $hotkeyKeyCode,
                    modifiers: $hotkeyModifiers,
                    isRecording: $isRecordingHotkey,
                    onHotkeyChanged: { keyCode, modifiers in
                        updateHotkey(keyCode: keyCode, modifiers: modifiers)
                    }
                )
                .frame(height: 36)
                
                Text("config.hotkey_instruction".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Presets Card
    
    private var presetsCard: some View {
        SettingsCard(icon: "sparkles", title: "settings.presets".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.presets_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 10) {
                    HotkeyPresetButton("⌥ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: optionKey)) {
                        updateHotkey(keyCode: 49, modifiers: optionKey)
                    }
                    
                    HotkeyPresetButton("⌘⇧ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: cmdKey | shiftKey)) {
                        updateHotkey(keyCode: 49, modifiers: cmdKey | shiftKey)
                    }
                    
                    HotkeyPresetButton("⌃⌥ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: controlKey | optionKey)) {
                        updateHotkey(keyCode: 49, modifiers: controlKey | optionKey)
                    }
                }
            }
        }
    }
    
    // MARK: - Permissions Card
    
    private var permissionsCard: some View {
        SettingsCard(icon: "hand.raised", title: "settings.permissions".localized) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.permissions_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button("settings.open_preferences".localized) {
                    openAccessibilityPreferences()
                }
                .buttonStyle(.link)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func isHotkeySelected(keyCode: Int, modifiers: Int) -> Bool {
        hotkeyKeyCode == keyCode && hotkeyModifiers == modifiers
    }
    
    private func updateHotkey(keyCode: Int, modifiers: Int) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        HotkeyManager.shared.updateHotkey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }
    
    private func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Hotkey Preset Button

struct HotkeyPresetButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    init(_ label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.sapoGreen : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HotkeySettingsTab()
        .frame(width: 480, height: 500)
}
