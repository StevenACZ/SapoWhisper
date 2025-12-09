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
                    Label("General", systemImage: "gear")
                }
            
            hotkeyTab
                .tabItem {
                    Label("Atajos", systemImage: "keyboard")
                }
            
            aboutTab
                .tabItem {
                    Label("Acerca de", systemImage: "info.circle")
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
                        Text("Micrófono")
                        Text("Dispositivo de entrada de audio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Picker(selection: $language) {
                    Label("Español", systemImage: "globe.europe.africa").tag("es")
                    Label("English", systemImage: "globe.americas").tag("en")
                    Divider()
                    Label("Detectar automáticamente", systemImage: "wand.and.stars").tag("auto")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Idioma de transcripción")
                        Text("El idioma que usarás para hablar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Audio")
            }

            Section {
                Toggle(isOn: $autoPaste) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pegar automáticamente")
                        Text("El texto se pegará donde tengas el cursor")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $playSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sonidos de feedback")
                        Text("Reproduce sonidos al grabar y transcribir")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Comportamiento")
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
                        Text("Atajo actual")
                        Text("Presiona para grabar/detener desde cualquier app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HotkeyDisplay(text: currentHotkeyDescription)
                }
            } header: {
                Text("Atajo de Teclado Global")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Atajos predefinidos")
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
                Text("Cambiar Atajo")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Permisos de Accesibilidad", systemImage: "hand.raised")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("Para que el atajo funcione en todas las aplicaciones, SapoWhisper necesita permisos de Accesibilidad.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Abrir Preferencias del Sistema") {
                        openAccessibilityPreferences()
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Permisos")
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
                
                Text("Versión \(Constants.appVersion)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text(Constants.appDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .frame(width: 200)
            
            VStack(spacing: 8) {
                Text("Creado con 💚 por Steven")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button {
                    if let url = URL(string: Constants.githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Ver en GitHub", systemImage: "link")
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
