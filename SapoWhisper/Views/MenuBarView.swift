//
//  MenuBarView.swift
//  SapoWhisper
//
//

import Combine
import SwiftUI

/// Vista principal del popup del menu bar - Diseño limpio y moderno
struct MenuBarView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @ObservedObject private var reachability = NetworkReachability.shared
    @Environment(\.openWindow) var openWindow
    var missingPermissions: [AppPermission] = []
    var openSettingsAction: (() -> Void)?
    var openHistoryAction: (() -> Void)?
    var openPermissionsAction: (() -> Void)?
    var openWelcomeAction: (() -> Void)?
    var openAboutAction: (() -> Void)?
    var closeMenuBarAction: (() -> Void)?
    @AppStorage(Constants.StorageKeys.onboardingComplete) private var onboardingComplete = false
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @State private var isHoveringRecord = false
    @State private var pulseAnimation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsEngineSetup: Bool {
        !onboardingComplete && !viewModel.isLoadingWhisperKit && !viewModel.isEngineReady(viewModel.currentEngine)
    }

    /// R7: only the cloud engines lose anything while offline.
    private var showsOfflineHint: Bool {
        reachability.isOffline && viewModel.currentEngine.requiresInternet
    }

    private var showsOfflinePolishHint: Bool {
        aiPolishEnabled
            && !viewModel.currentEngine.requiresInternet
            && PolishProviderConfiguration.hostedEndpointIsPausedOffline()
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            MenuBarPermissionReminderView(missingPermissions: missingPermissions) {
                openPermissionsWindow()
            }

            if showsOfflineHint {
                offlineHintBanner
            }

            if showsOfflinePolishHint {
                offlinePolishHintBanner
            }

            if needsEngineSetup {
                setupReminderBanner
            }

            recordingSection

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
                    if reduceMotion {
                        // Static ring instead of the expanding pulse.
                        Circle()
                            .stroke(viewModel.appState.iconColor.opacity(0.5), lineWidth: 2)
                            .frame(width: 44, height: 44)
                    } else {
                        Circle()
                            .stroke(viewModel.appState.iconColor, lineWidth: 2)
                            .frame(width: 44, height: 44)
                            .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                            .opacity(pulseAnimation ? 0 : 1)
                            .animation(.easeOut(duration: 1).repeatForever(autoreverses: false), value: pulseAnimation)
                            .onAppear { pulseAnimation = true }
                            .onDisappear { pulseAnimation = false }
                    }
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

                if case .recording = viewModel.appState {
                    // The live seconds counter subscribes on its own so the
                    // 10 Hz ticks never invalidate the whole popover.
                    RecordingStatusCaption(
                        durationPublisher: viewModel.recordingDurationSubject.eraseToAnyPublisher()
                    )
                } else {
                    Text(viewModel.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
                RecordingTimerRow(durationPublisher: viewModel.recordingDurationSubject.eraseToAnyPublisher())
                    .transition(.scale.combined(with: .opacity))
            }

            Button(action: {
                withAnimation(Constants.Animation.morph) {
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
                            // Constant value under Reduce Motion: never bounces.
                            .symbolEffect(.bounce, value: reduceMotion ? false : viewModel.audioRecorder.isRecording)
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
        .animation(Constants.Animation.morph, value: viewModel.appState)
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
        // Exhaustive switch (mirrors buttonColor) so foreground and background
        // can never diverge: .noModel/.error paint the neutral gray gradient,
        // not the idle green one.
        let colors: [Color]
        switch viewModel.appState {
        case .recording:
            colors = [Color.recording, Color.recording.opacity(0.8)]
        case .processing:
            colors = [Color.processing, Color.processing.opacity(0.8)]
        case .polishing:
            colors = [Color.aiPolish, Color.aiPolish.opacity(0.8)]
        case .noModel, .error:
            colors = [Color.disabled, Color.disabled.opacity(0.8)]
        default:
            colors = [Color.sapoGreen, Color.sapoGreenDark]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 0) {
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
                subtitle: viewModel.currentEngine.displayName
            ) {
                openSettingsWindow()
            }

            Divider()
                .padding(.horizontal)

            ActionRow(
                icon: "info.circle",
                title: "menu.about".localized,
                subtitle: nil
            ) {
                openAboutWindow()
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

    // MARK: - Offline Hint (R7)

    private var offlineHintBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text("menu.offline_hint".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var offlinePolishHintBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text("menu.offline_polish_hint".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Setup Reminder

    private var setupReminderBanner: some View {
        Button(action: openWelcomeWindow) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sapoGreen)

                VStack(alignment: .leading, spacing: 1) {
                    Text("menu.setup_pending_title".localized)
                        .font(.caption.weight(.semibold))
                    Text("menu.setup_pending_subtitle".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.sapoGreen.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.sapoGreen.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
    }

    private func openWelcomeWindow() {
        if let openWelcomeAction {
            openWelcomeAction()
        } else {
            closeMenuBarAction?()
            WelcomeWindowController.shared.show()
        }
    }
}

#Preview("Menu Bar Popup") {
    MenuBarView(viewModel: SapoWhisperViewModel())
        .frame(width: 320)
}
