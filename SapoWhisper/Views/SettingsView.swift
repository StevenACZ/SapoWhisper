//
//  SettingsView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Carbon

/// Vista de configuración de la aplicación
struct SettingsView: View {
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("playSound") private var playSound = true
    @AppStorage("language") private var language = "es"
    
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
        .frame(width: 450, height: 300)
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section("Comportamiento") {
                Toggle("Pegar automáticamente al terminar", isOn: $autoPaste)
                Toggle("Reproducir sonido al grabar", isOn: $playSound)
            }
            
            Section("Idioma de transcripción") {
                Picker("Idioma", selection: $language) {
                    Text("Español").tag("es")
                    Text("English").tag("en")
                    Text("Detectar automáticamente").tag("auto")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Hotkey Tab
    
    private var hotkeyTab: some View {
        Form {
            Section("Atajo actual") {
                HStack {
                    Text("Grabar/Detener:")
                    Spacer()
                    Text(HotkeyManager.shared.hotkeyDescription)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(6)
                }
            }
            
            Section("Atajos predefinidos") {
                HStack(spacing: 10) {
                    hotkeyButton("⌥ Space", keyCode: 49, modifiers: UInt32(optionKey))
                    hotkeyButton("⌘⇧ Space", keyCode: 49, modifiers: UInt32(cmdKey | shiftKey))
                    hotkeyButton("⌃⌥ Space", keyCode: 49, modifiers: UInt32(controlKey | optionKey))
                }
            }
            
            Text("Nota: Necesitas permisos de Accesibilidad para que los atajos funcionen globalmente.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private func hotkeyButton(_ label: String, keyCode: UInt32, modifiers: UInt32) -> some View {
        Button(label) {
            HotkeyManager.shared.updateHotkey(keyCode: keyCode, modifiers: modifiers) {
                // El callback se manejará por el ViewModel
            }
        }
        .buttonStyle(.bordered)
    }
    
    // MARK: - About Tab
    
    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("SapoWhisper")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Versión 1.0.0")
                .foregroundColor(.secondary)
            
            Text("Speech-to-Text 100% local usando Whisper")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            Text("Creado por Steven")
                .font(.caption)
            
            Link("GitHub", destination: URL(string: "https://github.com/StevenACZ")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    SettingsView()
}
