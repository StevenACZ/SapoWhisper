//
//  ModelDownloadView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Vista para descargar y gestionar modelos de Whisper
struct ModelDownloadView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Lista de modelos
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(WhisperModel.allCases) { model in
                        ModelRowView(
                            model: model,
                            isDownloading: viewModel.downloadManager.currentModel == model,
                            downloadProgress: viewModel.downloadManager.downloadProgress,
                            onDownload: { viewModel.downloadModel(model) },
                            onLoad: {
                                Task {
                                    await viewModel.loadModel(model)
                                    dismiss()
                                }
                            }
                        )
                    }
                }
                .padding()
            }
            
            // Error message
            if let error = viewModel.downloadManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding()
            }
            
            Divider()
            
            // Footer
            footerSection
        }
        .frame(width: 400, height: 500)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.largeTitle)
                .foregroundColor(.blue)
            
            Text("Modelos de Whisper")
                .font(.headline)
            
            Text("Selecciona el modelo que quieres usar. Los más grandes son más precisos pero más lentos.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
    
    private var footerSection: some View {
        HStack {
            Button("Cerrar") {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding()
    }
}

/// Fila individual para cada modelo
struct ModelRowView: View {
    let model: WhisperModel
    let isDownloading: Bool
    let downloadProgress: Double
    let onDownload: () -> Void
    let onLoad: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Info del modelo
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.displayName)
                        .font(.headline)
                    
                    if model.isRecommended {
                        Text("RECOMENDADO")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .cornerRadius(4)
                    }
                }
                
                HStack {
                    Text(model.fileSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text(model.speed)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    // Estrellas de precisión
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in
                            Image(systemName: i < model.accuracy ? "star.fill" : "star")
                                .font(.system(size: 8))
                                .foregroundColor(i < model.accuracy ? .yellow : .gray)
                        }
                    }
                }
            }
            
            Spacer()
            
            // Estado / Acción
            if isDownloading {
                VStack(spacing: 4) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 80)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if model.isDownloaded {
                Button("Usar") {
                    onLoad()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button("Descargar") {
                    onDownload()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(model.isDownloaded ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(model.isDownloaded ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

#Preview {
    ModelDownloadView(viewModel: SapoWhisperViewModel())
}
