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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Constants.Colors.sapoGreen)
                    .frame(width: 18, alignment: .leading)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Sección de información con icono, título y contenido de texto
struct InfoSection: View {
    let icon: String
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Constants.Colors.sapoGreen)
                    .frame(width: 18, alignment: .leading)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
