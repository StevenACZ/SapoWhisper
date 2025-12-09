//
//  MenuBarView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Vista principal del popup del menu bar - Diseño limpio y moderno
struct MenuBarView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var isHoveringRecord = false
    @State private var pulseAnimation = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header con estado
            headerSection
            
            // Botón principal de grabación
            recordingSection
            
            // Última transcripción
            if !viewModel.lastTranscription.isEmpty {
                transcriptionSection
            }
            
            Divider()
                .padding(.horizontal)
            
            // Configuraciones rápidas y acciones
            actionsSection
        }
        .frame(width: Constants.Sizes.menuBarWidth)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            // Icono del sapo
            ZStack {
                Circle()
                    .fill(viewModel.appState.iconColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                
                if case .recording = viewModel.appState {
                    Circle()
                        .stroke(viewModel.appState.iconColor, lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                        .opacity(pulseAnimation ? 0 : 1)
                        .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: pulseAnimation)
                        .onAppear { pulseAnimation = true }
                        .onDisappear { pulseAnimation = false }
                }
                
                // Usar siempre el icono Idle para el header del popup
                if let idleIcon = NSImage(named: "DockIconIdle") {
                    Image(nsImage: idleIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("app_name".localized)
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Badge del hotkey
            HotkeyBadge(text: viewModel.hotkeyManager.hotkeyDescription)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - Recording Section
    
    private var recordingSection: some View {
        VStack(spacing: 16) {
            // Timer de grabación (si está grabando)
            if case .recording = viewModel.appState {
                RecordingTimer(duration: viewModel.recordingDuration)
                    .transition(.scale.combined(with: .opacity))
            }
            
            // Botón principal
            Button(action: {
                withAnimation(Constants.Animation.spring) {
                    viewModel.toggleRecording()
                }
            }) {
                HStack(spacing: 12) {
                    if case .processing = viewModel.appState {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.bounce, value: viewModel.audioRecorder.isRecording)
                    }
                    
                    Text(buttonText)
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Constants.Sizes.buttonHeight)
                .background(buttonBackground)
                .foregroundColor(.white)
                .cornerRadius(Constants.Sizes.cornerRadius)
                .scaleEffect(isHoveringRecord ? 1.02 : 1.0)
                .shadow(color: buttonColor.opacity(0.3), radius: isHoveringRecord ? 8 : 4, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRecord)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHoveringRecord = hovering
                }
            }
            
            // Mensaje si no hay modelo
            if case .noModel = viewModel.appState {
                Button(action: { openSettingsWindow() }) {
                    Label("menu.configure_details".localized, systemImage: "arrow.down.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.link)
            }
        }
        .padding()
        .animation(.spring(response: 0.3), value: viewModel.appState)
    }
    
    private var buttonIcon: String {
        switch viewModel.appState {
        case .recording:
            return "stop.fill"
        case .processing:
            return "hourglass"
        default:
            return "mic.fill"
        }
    }
    
    private var buttonText: String {
        switch viewModel.appState {
        case .recording:
            return "menu.stop_recording".localized
        case .processing:
            return "menu.transcribing".localized
        case .noModel:
            return "menu.no_model".localized
        default:
            return "menu.start_recording".localized
        }
    }
    
    private var buttonColor: Color {
        switch viewModel.appState {
        case .recording:
            return .recording
        case .processing:
            return .processing
        case .noModel, .error:
            return .disabled
        default:
            return .sapoGreen
        }
    }
    
    private var buttonBackground: some View {
        Group {
            if case .recording = viewModel.appState {
                LinearGradient(
                    colors: [Color.recording, Color.recording.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if case .processing = viewModel.appState {
                LinearGradient(
                    colors: [Color.processing, Color.processing.opacity(0.8)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [Color.sapoGreen, Color.sapoGreenDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
    
    // MARK: - Transcription Section
    
    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.quote")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                Text("menu.last_transcription".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    PasteManager.copyToClipboard(viewModel.lastTranscription)
                    SoundManager.shared.play(.success)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("menu.copy_clipboard".localized)
            }
            
            Text(viewModel.lastTranscription)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(Constants.Sizes.smallCornerRadius)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(spacing: 0) {
            // Toggle de auto-paste
            SettingsRow(
                icon: "doc.on.clipboard",
                title: "menu.auto_paste".localized,
                subtitle: "menu.auto_paste_sub".localized
            ) {
                Toggle("", isOn: $viewModel.autoPasteEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            
            Divider()
                .padding(.horizontal)
            
            // Configuración - Abre ventana separada
            ActionRow(
                icon: "gearshape",
                title: "menu.settings".localized,
                subtitle: viewModel.transcriber.loadedModelName ?? "Speech Recognition"
            ) {
                openSettingsWindow()
            }
            
            Divider()
                .padding(.horizontal)
            
            // Salir
            ActionRow(
                icon: "power",
                title: "quit".localized,
                subtitle: nil,
                isDestructive: true
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Helpers
    
    private func openSettingsWindow() {
        // Cerrar el popup del menu bar
        NSApp.keyWindow?.close()
        
        // Abrir la ventana de configuración
        openWindow(id: "settings")
        
        // Activar la app para que la ventana aparezca al frente
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

// MARK: - Supporting Views

/// Badge que muestra el atajo de teclado
struct HotkeyBadge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
    }
}

/// Timer visual de la grabación
struct RecordingTimer: View {
    let duration: TimeInterval
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.recording)
                .frame(width: 8, height: 8)
            
            Text(formattedDuration)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.recording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.recording.opacity(0.1))
        .cornerRadius(Constants.Sizes.smallCornerRadius)
    }
    
    private var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, milliseconds)
    }
}

/// Fila de configuración con toggle
struct SettingsRow<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let content: () -> Content
    
    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            content()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

/// Fila de acción clickeable
struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var isDestructive: Bool = false
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isDestructive ? .red : .secondary)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(isDestructive ? .red : .primary)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if !isDestructive {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(isHovering ? Color(NSColor.controlBackgroundColor) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

#Preview {
    MenuBarView(viewModel: SapoWhisperViewModel())
        .frame(width: 320)
}
