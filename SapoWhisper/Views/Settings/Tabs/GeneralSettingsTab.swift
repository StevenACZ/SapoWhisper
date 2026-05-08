//
//  GeneralSettingsTab.swift
//  SapoWhisper
//
//

import Foundation
import ServiceManagement
import SwiftUI
import os

/// Tab de configuracion general con Form nativo (.grouped)
struct GeneralSettingsTab: View {
    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.soundVolume) private var soundVolume: Double = 1.0
    @AppStorage(Constants.StorageKeys.autoDuckingEnabled) private var autoDuckingEnabled = false
    @AppStorage(Constants.StorageKeys.autoDuckingAmount) private var autoDuckingAmount: Double = 0.8
    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.appleOnline.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedDeepgramMode = DeepgramTranscriptionMode.nova3.rawValue
    @AppStorage(Constants.StorageKeys.deepgramPreviousLanguage) private var deepgramPreviousLanguage = ""

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    private let preferredMicrophoneCoordinator = PreferredMicrophoneCoordinator.shared

    private var appBinding: Binding<String> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }

    private var isInputLanguageLocked: Bool {
        selectedEngine == TranscriptionEngine.deepgram.rawValue && selectedDeepgramMode == DeepgramTranscriptionMode.fluxLive.rawValue
    }

    private var inputLanguageBinding: Binding<String> {
        Binding(
            get: { isInputLanguageLocked ? "auto" : selectedLanguage },
            set: { newValue in
                guard !isInputLanguageLocked else { return }
                selectedLanguage = newValue
            }
        )
    }

    var body: some View {
        Form {
            microphoneSection
            languageSection
            soundSection
            autoDuckingSection
            behaviorSection
            permissionsSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Constants.Colors.sapoGreen)
        .onAppear {
            refreshAudioDevicesForAppearance()
            enforceFluxLanguageLock()
        }
        .onChange(of: selectedEngine) { _, _ in
            enforceFluxLanguageLock()
        }
        .onChange(of: selectedDeepgramMode) { _, _ in
            enforceFluxLanguageLock()
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section {
            Picker("settings.microphone_desc".localized, selection: $selectedMicrophone) {
                ForEach(audioDeviceManager.availableDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .onChange(of: selectedMicrophone) { _, newUID in
                syncSystemDefaultInput(uid: newUID)
            }

            AudioLevelMeterView(deviceUID: selectedMicrophone)
        } header: {
            Label("settings.microphone".localized, systemImage: "mic.fill")
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

    // MARK: - Language (combined)

    private var languageSection: some View {
        Section {
            // Input language
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.input_language".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: inputLanguageBinding)
                    LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: inputLanguageBinding)
                    LanguageButton(name: "lang.auto".localized, flag: "🌐", languageCode: "auto", selectedLanguage: inputLanguageBinding)
                }
                .disabled(isInputLanguageLocked)
                .opacity(isInputLanguageLocked ? 0.65 : 1)

                if isInputLanguageLocked {
                    Label("settings.flux_language_locked".localized, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // App language
            VStack(alignment: .leading, spacing: 8) {
                Text("config.app_language".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: appBinding)
                    LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: appBinding)
                }
            }
        } header: {
            Label("settings.language_header".localized, systemImage: "globe")
        }
    }

    // MARK: - Sound

    private var soundSection: some View {
        Section {
            Toggle("settings.play_sounds".localized, isOn: $playSound)

            if playSound {
                Slider(value: $soundVolume, in: 0.05...1.0, step: 0.05) {
                    Text("settings.sound_volume".localized)
                } minimumValueLabel: {
                    Text("5%")
                } maximumValueLabel: {
                    Text("\(Int(soundVolume * 100))%")
                }
                .tint(Constants.Colors.sapoGreen)

                Button(action: {
                    SoundManager.shared.play(.success)
                }) {
                    Label("settings.test_sound".localized, systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Constants.Colors.sapoGreen)
            }
        } header: {
            Label("settings.sounds".localized, systemImage: "speaker.wave.2.fill")
        } footer: {
            Text("settings.play_sounds_desc".localized)
        }
    }

    // MARK: - Auto-Ducking

    private var autoDuckingSection: some View {
        Section {
            Toggle("settings.auto_ducking".localized, isOn: $autoDuckingEnabled)

            if autoDuckingEnabled {
                Slider(value: $autoDuckingAmount, in: 0.1...1.0, step: 0.05) {
                    Text("settings.ducking_amount".localized)
                } minimumValueLabel: {
                    Text("10%")
                } maximumValueLabel: {
                    Text("\(Int(autoDuckingAmount * 100))%")
                }
                .tint(Constants.Colors.sapoGreen)
            }
        } header: {
            Label("settings.auto_ducking_header".localized, systemImage: "speaker.minus.fill")
        } footer: {
            Text("settings.auto_ducking_desc".localized)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("settings.auto_paste".localized, isOn: $autoPaste)

            Toggle("settings.launch_at_login".localized, isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(enabled: newValue)
                }
        } header: {
            Label("settings.behavior".localized, systemImage: "gearshape")
        } footer: {
            Text("settings.auto_paste_desc".localized)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            ForEach(AppPermission.allCases) { permission in
                PermissionStatusRow(permission: permission)
            }

            Button("permissions.review".localized) {
                PermissionRequirementsWindowController.shared.showWindow(force: true)
            }
        } header: {
            Label("settings.permissions".localized, systemImage: "hand.raised.fill")
        } footer: {
            Text("settings.permissions_guided_footer".localized)
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

    private func enforceFluxLanguageLock() {
        guard isInputLanguageLocked else { return }
        if selectedLanguage != "auto" {
            deepgramPreviousLanguage = selectedLanguage
        }
        selectedLanguage = "auto"
    }
}

#Preview("General Settings") {
    GeneralSettingsTab()
        .frame(width: 480, height: 600)
}
