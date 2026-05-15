//
//  ElevenLabsSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct ElevenLabsSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.elevenLabsAPIKey) private var elevenLabsAPIKey = ""

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
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
        .onChange(of: elevenLabsAPIKey) { _, _ in
            viewModel.setEngine(.elevenLabsScribe)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyStatus

            SecureField("config.elevenlabs_key_placeholder".localized, text: $elevenLabsAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("config.elevenlabs_key_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
