//
//  SettingsView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Carbon

/// Vista de configuración de la aplicación - Diseño moderno y limpio
struct SettingsView: View {
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.language) private var language = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) private var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) private var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("settings.general".localized, systemImage: "gear")
                }
            
            hotkeyTab
                .tabItem {
                    Label("settings.hotkeys".localized, systemImage: "keyboard")
                }
            
            aboutTab
                .tabItem {
                    Label("settings.about".localized, systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 360)
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section {
                Picker(selection: $selectedMicrophone) {
                    ForEach(audioDeviceManager.availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.microphone".localized)
                        Text("settings.microphone_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Selector de idioma de la App
                Picker(selection: LocalizationManager.shared.$language) {
                    Text("lang.spanish".localized).tag("es")
                    Text("lang.english".localized).tag("en")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("config.app_language".localized)
                        Text("config.app_language_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Picker(selection: $language) {
                    Label("lang.spanish".localized, systemImage: "globe.europe.africa").tag("es")
                    Label("lang.english".localized, systemImage: "globe.americas").tag("en")
                    Divider()
                    Label("lang.auto".localized, systemImage: "wand.and.stars").tag("auto")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.input_language".localized)
                        Text("settings.input_language_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("settings.audio".localized)
            }

            Section {
                Toggle(isOn: $autoPaste) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.auto_paste".localized)
                        Text("settings.auto_paste_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $playSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.feedback_sounds".localized)
                        Text("settings.feedback_sounds_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("settings.behavior".localized)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            audioDeviceManager.refreshDevices()
        }
    }
    
    // MARK: - Hotkey Tab
    
    private var hotkeyTab: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.current_hotkey".localized)
                        Text("settings.current_hotkey_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HotkeyDisplay(text: currentHotkeyDescription)
                }
            } header: {
                Text("settings.hotkey_global".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("settings.presets".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        HotkeyButton("⌥ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: optionKey)) {
                            updateHotkey(keyCode: 49, modifiers: optionKey)
                        }

                        HotkeyButton("⌘⇧ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: cmdKey | shiftKey)) {
                            updateHotkey(keyCode: 49, modifiers: cmdKey | shiftKey)
                        }

                        HotkeyButton("⌃⌥ Space", isSelected: isHotkeySelected(keyCode: 49, modifiers: controlKey | optionKey)) {
                            updateHotkey(keyCode: 49, modifiers: controlKey | optionKey)
                        }
                    }
                }
            } header: {
                Text("settings.change_hotkey".localized)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("settings.permissions_title".localized, systemImage: "hand.raised")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("settings.permissions_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("settings.open_preferences".localized) {
                        openAccessibilityPreferences()
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("settings.permissions".localized)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func isHotkeySelected(keyCode: Int, modifiers: Int) -> Bool {
        hotkeyKeyCode == keyCode && hotkeyModifiers == modifiers
    }

    private var currentHotkeyDescription: String {
        var parts: [String] = []

        if hotkeyModifiers & controlKey != 0 { parts.append("⌃") }
        if hotkeyModifiers & optionKey != 0 { parts.append("⌥") }
        if hotkeyModifiers & shiftKey != 0 { parts.append("⇧") }
        if hotkeyModifiers & cmdKey != 0 { parts.append("⌘") }

        switch hotkeyKeyCode {
        case 49: parts.append("Space")
        case 36: parts.append("Return")
        default: parts.append("Key\(hotkeyKeyCode)")
        }

        return parts.joined(separator: " + ")
    }

    private func updateHotkey(keyCode: Int, modifiers: Int) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        HotkeyManager.shared.updateHotkey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) {
            // Callback vacío - se maneja desde el ViewModel
        }
    }
    
    private func openAccessibilityPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - About Tab
    
    private var aboutTab: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Logo del sapo
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 110, height: 110)
                
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            
            VStack(spacing: 6) {
                Text(Constants.appName)
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("version".localized(Constants.appVersion))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("app.description".localized)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .frame(width: 200)
            
            VStack(spacing: 8) {
                Text("made_by".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button {
                    if let url = URL(string: Constants.githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("settings.view_github".localized, systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Supporting Views

struct HotkeyDisplay: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .fontWeight(.medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.sapoGreen.opacity(0.1))
            .foregroundColor(.sapoGreen)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.sapoGreen.opacity(0.3), lineWidth: 1)
            )
    }
}

struct HotkeyButton: View {
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
    SettingsView()
}
