//
//  GeneralSettingsTab.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI
import ServiceManagement

/// Tab de configuracion general con Form nativo (.grouped)
struct GeneralSettingsTab: View {
    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.soundVolume) private var soundVolume: Double = 1.0

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var appBinding: Binding<String> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }

    var body: some View {
        Form {
            microphoneSection
            languageSection
            soundSection
            behaviorSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            audioDeviceManager.refreshDevices()
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

            AudioLevelMeterView(deviceUID: selectedMicrophone)
        } header: {
            Label("settings.microphone".localized, systemImage: "mic.fill")
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
                    LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: $selectedLanguage)
                    LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: $selectedLanguage)
                    LanguageButton(name: "lang.auto".localized, flag: "🌐", languageCode: "auto", selectedLanguage: $selectedLanguage)
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
                Slider(value: $soundVolume, in: 0.0...1.0) {
                    Text("settings.sound_volume".localized)
                } minimumValueLabel: {
                    Text("")
                } maximumValueLabel: {
                    Text("\(Int(soundVolume * 100))%")
                }
                .tint(Constants.Colors.sapoGreen)
                .onChange(of: soundVolume) { _, newValue in
                    if newValue < 0.01 {
                        soundVolume = 0.5
                        playSound = false
                    }
                }

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
    GeneralSettingsTab()
        .frame(width: 480, height: 600)
}
