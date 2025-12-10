//
//  SettingsCard.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
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

#Preview {
    VStack {
        SettingsCard(icon: "gear", title: "Configuración") {
            Text("Contenido de ejemplo")
                .foregroundColor(.secondary)
        }
        
        InfoSection(
            icon: "info.circle",
            title: "Información",
            content: "Este es un texto de ejemplo para la sección de información."
        )
    }
    .padding()
}
