//
//  MenuBarView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Vista principal del popup del menu bar
struct MenuBarView: View {
    @StateObject private var viewModel = SapoWhisperViewModel()
    @State private var showModelDownload = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Estado y botón principal
            mainSection
            
            // Última transcripción (si existe)
            if !viewModel.lastTranscription.isEmpty {
                Divider()
                lastTranscriptionSection
            }
            
            Divider()
            
            // Acciones
            actionsSection
        }
        .frame(width: 300)
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView(viewModel: viewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            Image(systemName: viewModel.appState.iconName)
                .font(.title2)
                .foregroundColor(viewModel.appState.iconColor)
            
            Text("SapoWhisper")
                .font(.headline)
            
            Spacer()
            
            Text(viewModel.hotkeyManager.hotkeyDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
        .padding()
    }
    
    // MARK: - Main Section
    
    private var mainSection: some View {
        VStack(spacing: 12) {
            // Estado actual
            HStack {
                Circle()
                    .fill(viewModel.appState.iconColor)
                    .frame(width: 8, height: 8)
                
                Text(viewModel.statusText)
                    .font(.subheadline)
                
                Spacer()
                
                if case .recording = viewModel.appState {
                    Text(formatDuration(viewModel.audioRecorder.recordingDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            
            // Botón de grabar
            Button(action: viewModel.toggleRecording) {
                HStack {
                    if case .processing = viewModel.appState {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(.trailing, 4)
                    }
                    
                    Text(viewModel.recordButtonText)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonColor)
            .disabled(!viewModel.canRecord)
            
            // Mensaje si no hay modelo
            if case .noModel = viewModel.appState {
                Button("📦 Descargar Modelo") {
                    showModelDownload = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    private var buttonColor: Color {
        switch viewModel.appState {
        case .recording:
            return .red
        case .processing:
            return .orange
        default:
            return Color(red: 0.298, green: 0.686, blue: 0.314)
        }
    }
    
    // MARK: - Last Transcription
    
    private var lastTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Última transcripción")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    PasteManager.copyToClipboard(viewModel.lastTranscription)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copiar al portapapeles")
            }
            
            Text(viewModel.lastTranscription)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
    }
    
    // MARK: - Actions
    
    private var actionsSection: some View {
        VStack(spacing: 4) {
            HStack {
                Toggle("Auto-pegar", isOn: $viewModel.autoPasteEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            Button(action: { showModelDownload = true }) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                    Text("Modelos")
                    Spacer()
                    if let model = viewModel.transcriber.loadedModelName {
                        Text(model)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
            
            Divider()
            
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack {
                    Image(systemName: "power")
                    Text("Salir")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
    
    // MARK: - Helpers
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    MenuBarView()
}
