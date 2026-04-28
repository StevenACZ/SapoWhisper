//
//  SettingsCard.swift
//  SapoWhisper
//
//

import SwiftUI

/// Card contenedor reutilizable para secciones de configuración
struct SettingsCard<Content: View>: View {
    let icon: String
    let title: String
    let content: () -> Content
    
    init(icon: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
}

/// Sección de información con icono, título y contenido de texto
struct InfoSection: View {
    let icon: String
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            
            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
}

#Preview("Settings Cards") {
    VStack(spacing: 16) {
        SettingsCard(icon: "gear", title: "Configuration") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto-paste", isOn: .constant(true))
                Divider()
                Toggle("Launch at login", isOn: .constant(false))
            }
        }

        SettingsCard(icon: "mic.fill", title: "Microphone") {
            Text("MacBook Pro Microphone")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }

        InfoSection(
            icon: "lock.shield.fill",
            title: "Privacy",
            content: "All audio is processed locally on your device. No data is sent to external servers."
        )
    }
    .padding()
    .frame(width: 420)
}
