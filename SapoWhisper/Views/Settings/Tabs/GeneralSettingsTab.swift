//
//  GeneralSettingsTab.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI
import ServiceManagement

/// Tab de configuración general: idioma de la app, micrófono, idioma de entrada, comportamiento
struct GeneralSettingsTab: View {
    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    
    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                microphoneCard
                languageSelectionCard
                appLanguageCard
                soundSettingsCard
                behaviorCard
            }
            .padding()
        }
        .onAppear {
            audioDeviceManager.refreshDevices()
        }
    }
    
    // MARK: - App Language Card
    
    private var appBinding: Binding<String> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }
    
    private var appLanguageCard: some View {
        SettingsCard(icon: "gearshape.2", title: "config.app_language".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: appBinding)
                    LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: appBinding)
                }
                
                Text("config.app_language_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Microphone Card
    
    private var microphoneCard: some View {
        SettingsCard(icon: "mic.fill", title: "settings.microphone".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("settings.microphone_desc".localized, selection: $selectedMicrophone) {
                    ForEach(audioDeviceManager.availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.menu)
                
                Divider()
                
                // Audio level meter
                AudioLevelMeterView(deviceUID: selectedMicrophone)
            }
        }
    }
    
    // MARK: - Language Selection Card
    
    private var languageSelectionCard: some View {
        SettingsCard(icon: "globe", title: "settings.input_language".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: $selectedLanguage)
                    LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: $selectedLanguage)
                    LanguageButton(name: "lang.auto".localized, flag: "🌐", languageCode: "auto", selectedLanguage: $selectedLanguage)
                }
                
                Text("settings.input_language_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Behavior Card
    
    private var behaviorCard: some View {
        SettingsCard(icon: "gearshape", title: "settings.behavior".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $autoPaste) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.auto_paste".localized)
                        Text("settings.auto_paste_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()
                
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.launch_at_login".localized)
                        Text("settings.launch_at_login_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(enabled: newValue)
                }
            }
        }
    }
    
    // MARK: - Sound Settings Card
    
    @AppStorage(Constants.StorageKeys.soundVolume) private var soundVolume: Double = 1.0
    
    private var soundSettingsCard: some View {
        SettingsCard(icon: "speaker.wave.2.fill", title: "settings.sounds".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $playSound) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.play_sounds".localized)
                        Text("settings.play_sounds_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if playSound {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("settings.sound_volume".localized)
                            Spacer()
                            Text("\(Int(soundVolume * 100))%")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .monospacedDigit()
                        }
                        
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            
                            Slider(value: $soundVolume, in: 0.2...1.0, step: 0.1)
                                .tint(Constants.Colors.sapoGreen)
                            
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        
                        Text("settings.sound_volume_desc".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Botón para probar el sonido
                    Button(action: {
                        SoundManager.shared.play(.success)
                    }) {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text("settings.test_sound".localized)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Constants.Colors.sapoGreen)
                }
            }
        }
    }
    
    // MARK: - Launch at Login
    
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                print("✅ SapoWhisper registrado para iniciar al arrancar")
            } else {
                try SMAppService.mainApp.unregister()
                print("✅ SapoWhisper des-registrado del arranque")
            }
        } catch {
            print("❌ Error al configurar Launch at Login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview {
    GeneralSettingsTab()
        .frame(width: 480, height: 500)
}
