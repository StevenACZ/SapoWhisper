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

    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "auto"
    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.mlxWhisper.rawValue
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedDeepgramMode = DeepgramTranscriptionMode.nova3
        .rawValue
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.pinPrimaryMicrophone) private var pinPrimaryMicrophone = true
    @AppStorage(Constants.StorageKeys.audioUploadQuality) private var audioUploadQuality =
        AudioUploadQuality.defaultValue.rawValue
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.soundVolume) private var soundVolume: Double = 1.0
    @AppStorage(Constants.StorageKeys.autoDuckingEnabled) private var autoDuckingEnabled = false
    @AppStorage(Constants.StorageKeys.autoDuckingAmount) private var autoDuckingAmount: Double = 0.8

    @AppStorage(Constants.StorageKeys.historyAudioMaxMB) private var historyAudioMaxMB =
        HistoryAudioStorage.defaultMaxStorageMB
    @AppStorage(Constants.StorageKeys.historyAutoDeleteDays) private var historyAutoDeleteDays = 0
    @AppStorage(Constants.StorageKeys.overlayPosition) private var overlayPosition =
        OverlayPosition.bottom.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var historyAudioUsageBytes: Int64 = 0
    @State private var showClearHistoryConfirmation = false
    private let preferredMicrophoneCoordinator = PreferredMicrophoneCoordinator.shared

    private static let audioLimitOptionsMB = [250, 500, 1024, 2048]
    private static let autoDeleteOptionsDays = [0, 30, 90, 180]

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
                    historyRetentionCard
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

                if selectedMicrophone != AudioDevice.systemDefault.uid {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text("settings.pin_primary_mic".localized)
                                .font(.caption)
                            Spacer()
                            Toggle("", isOn: $pinPrimaryMicrophone)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .onChange(of: pinPrimaryMicrophone) { _, pinned in
                            if pinned {
                                syncSystemDefaultInput(uid: selectedMicrophone)
                            }
                        }

                        Text(
                            (pinPrimaryMicrophone
                                ? "settings.pin_primary_mic_desc_on"
                                : "settings.pin_primary_mic_desc_off").localized
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                audioUploadQualityPicker

                AudioLevelMeterView(deviceUID: selectedMicrophone)
            }
            .animation(Constants.Animation.reveal, value: selectedMicrophone)
        }
    }

    private var currentAudioUploadQuality: AudioUploadQuality {
        AudioUploadQuality(rawValue: audioUploadQuality) ?? .defaultValue
    }

    private var audioUploadQualityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("settings.audio_upload_quality".localized)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("settings.audio_upload_quality".localized, selection: $audioUploadQuality) {
                ForEach(AudioUploadQuality.allCases) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(currentAudioUploadQuality.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("settings.audio_upload_quality_desc".localized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Explicit AI-polish output language currently in effect, or nil when
    /// translation is off. Mirrors the effective target in TranscriptPostProcessor.
    private var aiTranslationTarget: TranscriptPolishOutputLanguage? {
        guard aiPolishEnabled else { return nil }
        let language = TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
        return language.requiresTranslation ? language : nil
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

                    if let target = aiTranslationTarget {
                        // Pinning the engine to the same language the AI
                        // outputs is coherent (speak X, get X) — only warn
                        // when the pin and the translation target diverge.
                        let pinMatchesTarget =
                            selectedLanguage == "auto" || selectedLanguage == target.nlLanguageCode
                        Label(
                            pinMatchesTarget
                                ? "settings.ai_translation_active".localized(target.displayName)
                                : "settings.ai_translation_language_pinned".localized(target.displayName),
                            systemImage: "sparkles"
                        )
                        .font(.caption)
                        .foregroundStyle(pinMatchesTarget ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
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
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    Button(action: {
                        SoundManager.shared.play(.success)
                    }) {
                        Label("settings.test_sound".localized, systemImage: "play.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Constants.Colors.sapoGreen)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Text("settings.play_sounds_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .animation(Constants.Animation.reveal, value: playSound)
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Text("settings.auto_ducking_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .animation(Constants.Animation.reveal, value: autoDuckingEnabled)
        }
    }

    // MARK: - History Retention Card (H6)

    private var historyRetentionCard: some View {
        SettingsCard(icon: "internaldrive", title: "settings.history_header".localized) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("settings.history_audio_limit".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $historyAudioMaxMB) {
                        ForEach(Self.audioLimitOptionsMB, id: \.self) { megabytes in
                            Text(formattedMB(megabytes)).tag(megabytes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                HStack {
                    Text("settings.history_audio_usage".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: historyAudioUsageBytes, countStyle: .file)
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Constants.Colors.sapoGreen)
                    .monospacedDigit()
                }

                HStack {
                    Text("settings.history_auto_delete".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $historyAutoDeleteDays) {
                        ForEach(Self.autoDeleteOptionsDays, id: \.self) { days in
                            Text(autoDeleteOptionLabel(days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text("settings.history_retention_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider()

                Button(role: .destructive) {
                    showClearHistoryConfirmation = true
                } label: {
                    Label("history.clear_all".localized, systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .confirmationDialog(
            "history.clear_all".localized,
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("history.delete".localized, role: .destructive) {
                TranscriptionHistoryManager.shared.deleteAll()
                refreshHistoryAudioUsage()
            }
        } message: {
            Text("history.clear_all_confirm_message".localized)
        }
        .task {
            refreshHistoryAudioUsage()
        }
    }

    private func formattedMB(_ megabytes: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(megabytes) * 1024 * 1024, countStyle: .file)
    }

    private func autoDeleteOptionLabel(_ days: Int) -> String {
        days == 0
            ? "settings.history_auto_delete_never".localized
            : "settings.history_auto_delete_days".localized(String(days))
    }

    private func refreshHistoryAudioUsage() {
        Task.detached(priority: .utility) {
            let usage = TranscriptionHistoryManager.shared.audioStorage.directorySize()
            await MainActor.run {
                historyAudioUsageBytes = usage
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

                HStack(spacing: 12) {
                    Text("settings.overlay_position".localized)
                    Spacer()
                    Picker("", selection: $overlayPosition) {
                        ForEach(OverlayPosition.allCases) { position in
                            Text(position.displayName).tag(position.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text("settings.auto_paste_desc".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider()

                HStack(spacing: 12) {
                    Text("menu.welcome_tour".localized)
                    Spacer()
                    Button("settings.welcome_tour_open".localized) {
                        WelcomeWindowController.shared.show()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
