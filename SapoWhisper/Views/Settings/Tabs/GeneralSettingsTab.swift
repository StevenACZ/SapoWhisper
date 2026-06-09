//
//  GeneralSettingsTab.swift
//  SapoWhisper
//
//

import Foundation
import ServiceManagement
import SwiftUI
import os

/// Tab de configuracion general con layout de 2 columnas usando SettingsCard
struct GeneralSettingsTab: View {
    let viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.whisperLocal.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedDeepgramMode = DeepgramTranscriptionMode.nova3
        .rawValue
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.soundVolume) private var soundVolume: Double = 1.0
    @AppStorage(Constants.StorageKeys.autoDuckingEnabled) private var autoDuckingEnabled = false
    @AppStorage(Constants.StorageKeys.autoDuckingAmount) private var autoDuckingAmount: Double = 0.8

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    private let preferredMicrophoneCoordinator = PreferredMicrophoneCoordinator.shared

    private var appBinding: Binding<String> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    microphoneCard
                    languageCard
                    behaviorCard
                    transferCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 12) {
                    autoDuckingCard
                    soundCard
                    permissionsCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(16)
        }
        .tint(Constants.Colors.sapoGreen)
        .onAppear {
            refreshAudioDevicesForAppearance()
        }
    }

    // MARK: - Microphone Card

    private var microphoneCard: some View {
        SettingsCard(icon: "mic.fill", title: "settings.microphone".localized) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.microphone_desc".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $selectedMicrophone) {
                        ForEach(audioDeviceManager.availableDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedMicrophone) { _, newUID in
                        syncSystemDefaultInput(uid: newUID)
                    }
                }

                AudioLevelMeterView(deviceUID: selectedMicrophone)
            }
        }
    }

    /// Reconciles the app selection with the macOS default input device
    private func syncSystemDefaultInput(uid: String) {
        preferredMicrophoneCoordinator.applyUserSelection(uid: uid)
    }

    private func refreshAudioDevicesForAppearance() {
        let t0 = CFAbsoluteTimeGetCurrent()
        SapoLog.settings.info("General settings scheduled audio device refresh")

        DispatchQueue.global(qos: .userInitiated).async {
            AudioDeviceManager.shared.refreshDevices()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            SapoLog.settings.info(
                "General settings audio devices refreshed elapsed=\(elapsed, privacy: .public)ms"
            )
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "settings-audio-devices-refreshed",
                context: "elapsedMs=\(elapsed)"
            )
        }
    }

    // MARK: - Language Card

    /// Flux Multilingual accepts a `language_hint` for a subset of the
    /// catalog; anything else falls back to auto-detect. Make that visible
    /// instead of silent when Flux live is the active mode.
    private var showsFluxHintUnsupportedBadge: Bool {
        guard selectedEngine == TranscriptionEngine.deepgram.rawValue,
            selectedDeepgramMode == DeepgramTranscriptionMode.fluxLive.rawValue,
            selectedLanguage != "auto"
        else {
            return false
        }
        return TranscriptionLanguageCatalog.deepgramFluxLanguageHint(for: selectedLanguage) == nil
    }

    private var languageCard: some View {
        SettingsCard(icon: "globe", title: "settings.language_header".localized) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.input_language".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("settings.input_language".localized, selection: $selectedLanguage) {
                        ForEach(TranscriptionLanguageCatalog.languages) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showsFluxHintUnsupportedBadge {
                        Label("settings.flux_hint_unsupported".localized, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("config.app_language".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: appBinding)
                        LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: appBinding)
                    }
                }
            }
        }
    }

    // MARK: - Sound Card

    private var soundCard: some View {
        SettingsCard(icon: "speaker.wave.2.fill", title: "settings.sounds".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("settings.play_sounds".localized)
                    Spacer()
                    Toggle("", isOn: $playSound)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if playSound {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.sound_volume".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(soundVolume * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Constants.Colors.sapoGreen)
                                .monospacedDigit()
                        }

                        Slider(value: $soundVolume, in: 0.05...1.0, step: 0.05)
                            .tint(Constants.Colors.sapoGreen)
                    }

                    Button(action: {
                        SoundManager.shared.play(.success)
                    }) {
                        Label("settings.test_sound".localized, systemImage: "play.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Constants.Colors.sapoGreen)
                }

                Text("settings.play_sounds_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Auto-Ducking Card

    private var autoDuckingCard: some View {
        SettingsCard(icon: "speaker.minus.fill", title: "settings.auto_ducking_header".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("settings.auto_ducking".localized)
                    Spacer()
                    Toggle("", isOn: $autoDuckingEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if autoDuckingEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.ducking_amount".localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(autoDuckingAmount * 100))%")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Constants.Colors.sapoGreen)
                                .monospacedDigit()
                        }

                        Slider(value: $autoDuckingAmount, in: 0.1...1.0, step: 0.05)
                            .tint(Constants.Colors.sapoGreen)
                    }
                }

                Text("settings.auto_ducking_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Behavior Card

    private var behaviorCard: some View {
        SettingsCard(icon: "gearshape", title: "settings.behavior".localized) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("settings.auto_paste".localized)
                    Spacer()
                    Toggle("", isOn: $autoPaste)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                HStack(spacing: 12) {
                    Text("settings.launch_at_login".localized)
                    Spacer()
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(enabled: newValue)
                        }
                }

                Text("settings.auto_paste_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Transfer Card

    private var transferCard: some View {
        SettingsTransferCard(viewModel: viewModel)
    }

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        SettingsCard(icon: "hand.raised.fill", title: "settings.permissions".localized) {
            SettingsPermissionsSection()
        }
    }

    // MARK: - Launch at Login

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

}

#Preview("General Settings") {
    GeneralSettingsTab(viewModel: SapoWhisperViewModel())
        .frame(width: 780, height: 560)
}
