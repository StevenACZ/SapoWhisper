//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIPolishSettingsCard: View {
    @ObservedObject private var promptContextManager = PromptContextManager.shared

    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishMode = TranscriptPolishMode.automatic.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    @State private var isGoogleConfigured = ServiceAccountManager.shared.isConfigured
    @State private var projectID = ServiceAccountManager.shared.projectID
    @State private var connectionMessage: String?

    private var currentPrompt: PromptProfile {
        promptContextManager.promptProfile(for: aiPolishMode)
    }

    private var currentOutputLanguage: TranscriptPolishOutputLanguage {
        if currentPrompt.forcesEnglish {
            return .english
        }
        return TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
    }

    var body: some View {
        SettingsCard(icon: "cloud.fill", title: "ai.google_ai.title".localized) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    googleCloudPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    Divider()
                        .frame(height: isGoogleConfigured ? 188 : 156)

                    aiPolishPanel
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                if !isGoogleConfigured {
                    Divider()

                    setupGuide
                }

                feedbackMessage
            }
        }
        .onAppear(perform: refreshState)
    }

    private var canEditPolish: Bool {
        isGoogleConfigured && aiPolishEnabled
    }

    private var googleCloudPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusBanner

            credentialScopePills

            if isGoogleConfigured {
                connectedActions
            }
        }
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            GoogleCloudIcon(size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isGoogleConfigured ? "ai.google_connected".localized : "ai.google_missing".localized)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Image(systemName: isGoogleConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isGoogleConfigured ? Color.sapoGreen : .orange)
                }

                Text(isGoogleConfigured ? "ai.google_connected_desc".localized : "ai.google_missing_desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let projectID {
                    Text(projectID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var credentialScopePills: some View {
        HStack(spacing: 6) {
            AIPolishPill(icon: "waveform", text: "Chirp 3", tint: .blue)
            AIPolishPill(icon: "sparkles", text: "Vertex AI", tint: .purple)
        }
        .padding(.leading, 52)
    }

    private var aiPolishPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ai.polish.enable".localized, isOn: aiPolishBinding)
                .font(.subheadline.weight(.semibold))
                .disabled(!isGoogleConfigured)

            VStack(alignment: .leading, spacing: 10) {
                modePicker
                outputLanguagePicker
            }
            .opacity(canEditPolish ? 1 : 0.62)

            if !isGoogleConfigured {
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
            .frame(width: 230, alignment: .leading)
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
                    .frame(width: 230, alignment: .leading)
            } else {
                Picker("ai.polish.output_language".localized, selection: $aiPolishOutputLanguage) {
                    ForEach(TranscriptPolishOutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 230, alignment: .leading)
                .disabled(!canEditPolish)
            }
        }
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ai.google_setup_intro".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AIPolishSetupStep(
                number: 1,
                title: "ai.google_step1_title".localized,
                detail: "ai.google_step1_detail".localized,
                command: "brew install google-cloud-sdk"
            )

            AIPolishSetupStep(
                number: 2,
                title: "ai.google_step2_title".localized,
                detail: "ai.google_step2_detail".localized,
                command: "gcloud auth application-default login"
            )

            AIPolishSetupStep(
                number: 3,
                title: "ai.google_step3_title".localized,
                detail: "ai.google_step3_detail".localized
            )

            HStack(spacing: 8) {
                Button {
                    detectGoogleCredentials()
                } label: {
                    Label("ai.google_detect_adc".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.sapoGreen)

                Button {
                    importGoogleCredentials()
                } label: {
                    Label("ai.google_import_json".localized, systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
            }

            Text("ai.google_json_hint".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                detectButton
                changeButton
                removeButton
            }

            VStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    detectButton
                    changeButton
                }

                removeButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var detectButton: some View {
        Button {
            detectGoogleCredentials()
        } label: {
            Label("config.service_account_detect".localized, systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var changeButton: some View {
        Button {
            importGoogleCredentials()
        } label: {
            Label("config.service_account_change".localized, systemImage: "doc.badge.plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            ServiceAccountManager.shared.remove()
            aiPolishEnabled = false
            refreshState()
        } label: {
            Label("config.service_account_remove".localized, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var feedbackMessage: some View {
        if let connectionMessage {
            Text(connectionMessage)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var aiPolishBinding: Binding<Bool> {
        Binding(
            get: { aiPolishEnabled && isGoogleConfigured },
            set: { newValue in
                aiPolishEnabled = newValue && isGoogleConfigured
                if newValue && !isGoogleConfigured {
                    connectionMessage = "ai.google_required".localized
                }
            }
        )
    }

    private func detectGoogleCredentials() {
        ServiceAccountManager.shared.reload()
        refreshState()
        connectionMessage = isGoogleConfigured ? nil : "ai.google_not_detected".localized
    }

    private func importGoogleCredentials() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "ai.google_import_panel_desc".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ServiceAccountManager.shared.importFile(from: url)
            connectionMessage = nil
        } catch {
            connectionMessage = error.localizedDescription
        }
        refreshState()
    }

    private func refreshState() {
        isGoogleConfigured = ServiceAccountManager.shared.isConfigured
        projectID = ServiceAccountManager.shared.projectID
        if !isGoogleConfigured {
            aiPolishEnabled = false
        }
    }
}

private struct GoogleCloudIcon: View {
    let size: CGFloat

    var body: some View {
        Image("GoogleCloudIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
    }
}

private struct AIPolishPill: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(0.26), lineWidth: 1)
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.sapoGreen)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.sapoGreen.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.sapoGreen.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct AIPolishSetupStep: View {
    let number: Int
    let title: String
    let detail: String
    var command: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.sapoGreen))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let command {
                    HStack(spacing: 6) {
                        Text(command)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5))

                        Button {
                            copy(command)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("ai.google_copy_command".localized)
                    }
                }
            }
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

#Preview("AI Polish Settings") {
    AIPolishSettingsCard()
        .frame(width: 700)
        .padding()
}
