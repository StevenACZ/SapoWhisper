//
//  ElevenLabsSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct ElevenLabsSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @State private var elevenLabsAPIKey = ""
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
            viewModel.setElevenLabsMode(currentMode)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSelector

            Divider()

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

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.elevenlabs_mode".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ForEach(ElevenLabsTranscriptionMode.allCases) { mode in
                    ElevenLabsModeButton(
                        mode: mode,
                        isSelected: currentMode == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
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

private struct ElevenLabsModeButton: View {
    let mode: ElevenLabsTranscriptionMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary.opacity(0.5))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.sapoGreen.opacity(0.1) : Color(NSColor.windowBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.sapoGreen.opacity(0.5) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview("ElevenLabs Settings") {
    ElevenLabsSettingsCard(viewModel: SapoWhisperViewModel())
        .padding()
        .frame(width: 360)
}
