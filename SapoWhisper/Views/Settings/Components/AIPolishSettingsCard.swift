//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

/// AI polish (Gemini in Vertex AI) controls. Reads its enabled-state requirement
/// from [[GoogleCredentialsState]] — credential lifecycle lives in
/// `GoogleCloudCredentialsCard`.
struct AIPolishSettingsCard: View {
    @ObservedObject var credentials: GoogleCredentialsState
    @ObservedObject private var promptContextManager = PromptContextManager.shared

    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishMode = TranscriptPolishMode.automatic.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    private var currentPrompt: PromptProfile {
        promptContextManager.promptProfile(for: aiPolishMode)
    }

    private var currentOutputLanguage: TranscriptPolishOutputLanguage {
        if currentPrompt.forcesEnglish {
            return .english
        }
        return TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
    }

    private var canEditPolish: Bool {
        credentials.isConfigured && aiPolishEnabled
    }

    var body: some View {
        SettingsCard(icon: "sparkles", title: "ai.polish.title".localized) {
            VStack(alignment: .leading, spacing: 12) {
                AIPolishHeroToggle(
                    isOn: aiPolishBinding,
                    isEnabled: credentials.isConfigured
                )

                VStack(alignment: .leading, spacing: 10) {
                    modePicker
                    outputLanguagePicker
                }
                .opacity(canEditPolish ? 1 : 0.62)

                if !credentials.isConfigured {
                    Label("ai.polish.requires_google".localized, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                AIPolishInfoCallout(
                    title: "ai.polish.vertex_info_title".localized,
                    detail: "ai.polish.desc".localized
                )
            }
        }
    }

    private var modePicker: some View {
        AIPolishSettingRow(
            title: "ai.polish.mode".localized,
            detail: "ai.polish.mode_desc".localized(currentPrompt.trimmedName)
        ) {
            Picker("ai.polish.mode".localized, selection: $aiPolishMode) {
                ForEach(promptContextManager.prompts) { prompt in
                    Text(prompt.trimmedName).tag(prompt.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!canEditPolish)
        }
    }

    private var outputLanguagePicker: some View {
        AIPolishSettingRow(
            title: "ai.polish.output_language".localized,
            detail: "ai.polish.output_language_desc".localized(currentOutputLanguage.displayName)
        ) {
            if currentPrompt.forcesEnglish {
                FixedValuePill(text: currentOutputLanguage.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("ai.polish.output_language".localized, selection: $aiPolishOutputLanguage) {
                    ForEach(TranscriptPolishOutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!canEditPolish)
            }
        }
    }

    private var aiPolishBinding: Binding<Bool> {
        Binding(
            get: { aiPolishEnabled && credentials.isConfigured },
            set: { newValue in
                aiPolishEnabled = newValue && credentials.isConfigured
                if newValue && !credentials.isConfigured {
                    credentials.connectionMessage = "ai.google_required".localized
                }
            }
        )
    }
}

private struct AIPolishSettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)

            control()

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FixedValuePill: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AIPolishInfoCallout: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.sapoGreen)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.sapoGreen)
                    .textCase(.uppercase)
                    .tracking(0.3)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sapoGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.sapoGreen.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct AIPolishHeroToggle: View {
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 34, height: 34)
                    .shadow(color: isOn ? Color.sapoGreen.opacity(0.35) : .clear, radius: 4, y: 1)

                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("ai.polish.enable".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(isOn ? "ai.polish.enable_active".localized : "ai.polish.enable_subtitle".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.sapoGreen)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.sapoGreen.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn ? Color.sapoGreen.opacity(0.38) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }

    private var iconBackground: LinearGradient {
        if isOn {
            return LinearGradient(
                colors: [Color.purple, Color.sapoGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.secondary.opacity(0.22), Color.secondary.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview("AI Polish Settings") {
    AIPolishSettingsCard(credentials: GoogleCredentialsState())
        .frame(width: 400)
        .padding()
}
