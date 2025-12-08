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
            
            Section {
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
                Text("Idioma")
            }
        }
        .formStyle(.grouped)
        .padding()
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
                    
                    HotkeyDisplay(text: HotkeyManager.shared.hotkeyDescription)
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
                        HotkeyButton("⌥ Space", isSelected: true) {
                            updateHotkey(keyCode: 49, modifiers: UInt32(optionKey))
                        }
                        
                        HotkeyButton("⌘⇧ Space", isSelected: false) {
                            updateHotkey(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey))
                        }
                        
                        HotkeyButton("⌃⌥ Space", isSelected: false) {
                            updateHotkey(keyCode: 49, modifiers: UInt32(controlKey | optionKey))
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
    
    private func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        HotkeyManager.shared.updateHotkey(keyCode: keyCode, modifiers: modifiers) {
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
            
            // Logo animado
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.sapoGreen, Color.sapoGreenDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
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
