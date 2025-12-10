//
//  WhisperModelButton.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

/// Botón para seleccionar modelo de WhisperKit
struct WhisperModelButton: View {
    let model: WhisperKitModel
    let isSelected: Bool
    let isLoading: Bool
    let isDownloaded: Bool
    let downloadedSize: Int64?
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    init(model: WhisperKitModel,
         isSelected: Bool,
         isLoading: Bool,
         isDownloaded: Bool = false,
         downloadedSize: Int64? = nil,
         action: @escaping () -> Void,
         onDelete: (() -> Void)? = nil) {
        self.model = model
        self.isSelected = isSelected
        self.isLoading = isLoading
        self.isDownloaded = isDownloaded
        self.downloadedSize = downloadedSize
        self.onSelect = action
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 12) {
            // Botón principal (seleccionar modelo)
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    // Radio button
                    ZStack {
                        Circle()
                            .stroke(isSelected ? Color.sapoGreen : Color.secondary.opacity(0.3), lineWidth: 2)
                            .frame(width: 20, height: 20)

                        if isSelected {
                            Circle()
                                .fill(Color.sapoGreen)
                                .frame(width: 12, height: 12)
                        }
                    }

                    // Info del modelo
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)

                            if model.isRecommended {
                                Text(model == .small ? "badge.balance".localized : "badge.pro".localized)
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(model == .small ? Color.blue : Color.purple)
                                    .cornerRadius(3)
                            }

                            // Indicador de descargado
                            if isDownloaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.sapoGreen)
                            }
                        }

                        HStack(spacing: 8) {
                            // Mostrar tamaño real si está descargado, sino el estimado
                            if isDownloaded, let size = downloadedSize {
                                Text(WhisperKitTranscriber.formatBytes(size))
                                    .font(.caption)
                                    .foregroundColor(.sapoGreen)
                            } else {
                                Text(model.fileSize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("•")
                                .foregroundColor(.secondary)

                            Text(model.speed)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("•")
                                .foregroundColor(.secondary)

                            // Estrellas de precisión
                            HStack(spacing: 1) {
                                ForEach(0..<5) { i in
                                    Image(systemName: i < model.accuracy ? "star.fill" : "star")
                                        .font(.system(size: 8))
                                        .foregroundColor(i < model.accuracy ? .yellow : .secondary.opacity(0.3))
                                }
                            }
                        }
                    }

                    Spacer()

                    // Indicador de estado
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if !isDownloaded {
                        // Mostrar icono de descarga si no está descargado
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            // Botón de borrar (solo si está descargado)
            if isDownloaded, let deleteAction = onDelete {
                Button(action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("model.delete_tooltip".localized)
            }
        }
        .padding(10)
        .background(isSelected ? Color.sapoGreen.opacity(0.08) : Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.sapoGreen.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview {
    VStack {
        WhisperModelButton(
            model: .small,
            isSelected: true,
            isLoading: false,
            isDownloaded: true,
            downloadedSize: 500_000_000,
            action: {},
            onDelete: {}
        )
        
        WhisperModelButton(
            model: .largev3Turbo,
            isSelected: false,
            isLoading: false,
            isDownloaded: false,
            action: {}
        )
    }
    .padding()
}
