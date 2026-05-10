//
//  MenuBarView.swift
//  SapoWhisper
//
//

import SwiftUI

/// Vista principal del popup del menu bar - Diseño limpio y moderno
struct MenuBarView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.openWindow) var openWindow
    var missingPermissions: [AppPermission] = []
    var openSettingsAction: (() -> Void)?
    var openHistoryAction: (() -> Void)?
    var openPermissionsAction: (() -> Void)?
    var closeMenuBarAction: (() -> Void)?
    @State private var isHoveringRecord = false
    @State private var pulseAnimation = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            MenuBarPermissionReminderView(missingPermissions: missingPermissions) {
                openPermissionsWindow()
            }

            recordingSection

            if !viewModel.lastTranscription.isEmpty {
                MenuBarTranscriptionSection(transcription: viewModel.lastTranscription) {
                    PasteManager.copyToClipboard(viewModel.lastTranscription)
                    SoundManager.shared.play(.success)
                }
            }

            Divider()
                .padding(.horizontal)

            actionsSection
        }
        .frame(width: Constants.Sizes.menuBarWidth)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 12) {
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

            HotkeyBadge(text: viewModel.hotkeyManager.hotkeyDescription)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Recording Section

    private var recordingSection: some View {
        VStack(spacing: 16) {
            if case .recording = viewModel.appState {
                RecordingTimer(duration: viewModel.recordingDuration)
                    .transition(.scale.combined(with: .opacity))
            }

            Button(action: {
                withAnimation(Constants.Animation.spring) {
                    viewModel.toggleRecording()
                }
            }) {
                HStack(spacing: 12) {
                    if viewModel.appState.isBusyProcessing {
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
        case .polishing:
            return "wand.and.stars"
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
        case .polishing:
            return "menu.ai_polishing".localized
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
        case .polishing:
            return .aiPolish
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
            } else if case .polishing = viewModel.appState {
                LinearGradient(
                    colors: [Color.aiPolish, Color.aiPolish.opacity(0.8)],
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

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 0) {
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

            ActionRow(
                icon: "clock.arrow.circlepath",
                title: "menu.history".localized,
                subtitle: nil
            ) {
                openHistoryWindow()
            }

            Divider()
                .padding(.horizontal)

            ActionRow(
                icon: "gearshape",
                title: "menu.settings".localized,
                subtitle: viewModel.transcriber.loadedModelName ?? "Speech Recognition"
            ) {
                openSettingsWindow()
            }

            Divider()
                .padding(.horizontal)

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

}

#Preview("Menu Bar Popup") {
    MenuBarView(viewModel: SapoWhisperViewModel())
        .frame(width: 320)
}
