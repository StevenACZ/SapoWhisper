//
//  EngineButton.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

/// Botón para seleccionar motor de transcripción
struct EngineButton: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    let isLoading: Bool
    let loadingProgress: Double
    let loadingMessage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icono
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                        .frame(width: 40, height: 40)

                    Image(systemName: engine.icon)
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .sapoGreen : .secondary)
                }

                // Texto
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(engine.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        if engine == .whisperLocal {
                            Text("badge.recommended".localized)
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.sapoGreen)
                                .cornerRadius(4)
                        }
                    }

                    Text(engine.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Indicador de selección o carga
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.sapoGreen)
                        .font(.system(size: 20))
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(12)
            .background(isSelected ? Color.sapoGreen.opacity(0.1) : Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.sapoGreen.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack {
        EngineButton(
            engine: .appleOnline,
            isSelected: true,
            isLoading: false,
            loadingProgress: 0,
            loadingMessage: ""
        ) {}
        
        EngineButton(
            engine: .whisperLocal,
            isSelected: false,
            isLoading: false,
            loadingProgress: 0,
            loadingMessage: ""
        ) {}
    }
    .padding()
}
