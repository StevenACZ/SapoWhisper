//
//  ElevenLabsSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct ElevenLabsSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @State private var elevenLabsAPIKey = ""
    @State private var keychainReadDenied = false
    @AppStorage(Constants.StorageKeys.elevenLabsTranscriptionMode) private var selectedMode =
        ElevenLabsTranscriptionMode.defaultMode.rawValue

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
    }

    private var currentMode: ElevenLabsTranscriptionMode {
        ElevenLabsTranscriptionMode(rawValue: selectedMode) ?? .defaultMode
    }

    var body: some View {
        Group {
            if isEmbedded {
                cardContent
            } else {
                SettingsCard(icon: "waveform.badge.magnifyingglass", title: "ElevenLabs Scribe v2") {
                    cardContent
                }
            }
        }
        .onChange(of: elevenLabsAPIKey) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (KeychainStore.string(for: .elevenLabsAPIKey) ?? "") else { return }
            KeychainStore.setString(trimmed, for: .elevenLabsAPIKey)
            viewModel.setEngine(.elevenLabsScribe)
        }
        .onAppear {
            elevenLabsAPIKey = KeychainStore.string(for: .elevenLabsAPIKey) ?? ""
            keychainReadDenied = KeychainStore.isReadDenied
            viewModel.setElevenLabsMode(currentMode)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSelector

            Divider()

            apiKeyStatus

            if keychainReadDenied {
                KeychainAccessRetryNotice {
                    elevenLabsAPIKey = KeychainStore.string(for: .elevenLabsAPIKey) ?? ""
                    keychainReadDenied = KeychainStore.isReadDenied
                }
            }

            SecureField("config.elevenlabs_key_placeholder".localized, text: $elevenLabsAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("config.elevenlabs_key_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.elevenlabs_mode".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ForEach(ElevenLabsTranscriptionMode.allCases) { mode in
                    EngineModeButton(
                        icon: mode.icon,
                        title: mode.displayName,
                        subtitle: mode.description,
                        isSelected: currentMode == mode
                    ) {
                        withAnimation(Constants.Animation.reveal) {
                            selectedMode = mode.rawValue
                            viewModel.setElevenLabsMode(mode)
                        }
                    }
                }
            }
        }
    }

    private var apiKeyStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: elevenLabsAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(elevenLabsAPIKey.isEmpty ? .orange : .sapoGreen)
            Text(
                elevenLabsAPIKey.isEmpty
                    ? "config.elevenlabs_key_missing".localized
                    : "config.elevenlabs_key_configured".localized
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }
}

#Preview("ElevenLabs Settings") {
    ElevenLabsSettingsCard(viewModel: SapoWhisperViewModel())
        .padding()
        .frame(width: 360)
}
