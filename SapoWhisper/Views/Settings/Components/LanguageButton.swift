//
//  LanguageButton.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

/// Botón para seleccionar idioma con bandera y nombre
struct LanguageButton: View {
    let name: String
    let flag: String
    let languageCode: String
    @Binding var selectedLanguage: String

    var isSelected: Bool {
        selectedLanguage == languageCode
    }

    var body: some View {
        Button(action: {
            selectedLanguage = languageCode
        }) {
            HStack(spacing: 4) {
                Text(flag)
                Text(name)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.windowBackgroundColor))
            .foregroundColor(isSelected ? .sapoGreen : .primary)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.sapoGreen : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview("Language Buttons") {
    HStack(spacing: 10) {
        LanguageButton(name: "Español", flag: "🇪🇸", languageCode: "es", selectedLanguage: .constant("es"))
        LanguageButton(name: "English", flag: "🇺🇸", languageCode: "en", selectedLanguage: .constant("es"))
        LanguageButton(name: "Auto", flag: "🌐", languageCode: "auto", selectedLanguage: .constant("es"))
    }
    .padding()
}
