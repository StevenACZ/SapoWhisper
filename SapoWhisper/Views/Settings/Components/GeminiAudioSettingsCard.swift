//
//  GeminiAudioSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct GeminiAudioSettingsCard: View {
    @ObservedObject var credentials: GoogleCredentialsState
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.geminiAudioModel) private var selectedModel =
        GeminiAudioModel.defaultModel.rawValue

    init(credentials: GoogleCredentialsState, isEmbedded: Bool = false) {
        self.credentials = credentials
        self.isEmbedded = isEmbedded
    }

    private var currentModel: GeminiAudioModel {
        GeminiAudioModel(rawValue: selectedModel) ?? .defaultModel
    }

    var body: some View {
        Group {
            if isEmbedded {
                cardContent
            } else {
                SettingsCard(icon: "sparkles", title: "gemini.audio.title".localized) {
                    cardContent
                }
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            credentialStatus
            modelPicker
            costCallout
            Text("gemini.audio.elevenlabs_note".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: credentials.isConfigured ? "checkmark.circle.fill" : "lock.fill")
                .foregroundColor(credentials.isConfigured ? .sapoGreen : .orange)
            Text(credentials.isConfigured ? "ai.google_connected".localized : "gemini.audio.requires_google".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("gemini.audio.model".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("gemini.audio.model".localized, selection: $selectedModel) {
                ForEach(GeminiAudioModel.allCases) { model in
                    Text(model.displayName).tag(model.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            HStack(spacing: 8) {
                if currentModel.isRecommended {
                    Text("badge.recommended".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.sapoGreen)
                        .cornerRadius(4)
                }

                Text(currentModel.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var costCallout: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "timer")
                .font(.caption)
                .foregroundStyle(.cyan)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("gemini.audio.cost_title".localized(currentModel.approximateFourMinuteCost))
                    .font(.caption.weight(.medium))
                Text("gemini.audio.cost_desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.cyan.opacity(0.09))
        .cornerRadius(8)
    }
}

#Preview("Gemini Audio Settings") {
    GeminiAudioSettingsCard(credentials: GoogleCredentialsState())
        .padding()
        .frame(width: 360)
}
