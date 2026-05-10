//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIPolishSettingsCard: View {
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishMode = TranscriptPolishMode.automatic.rawValue

    @State private var isGoogleConfigured = ServiceAccountManager.shared.isConfigured
    @State private var projectID = ServiceAccountManager.shared.projectID
    @State private var connectionMessage: String?

    private var currentMode: TranscriptPolishMode {
        TranscriptPolishMode(rawValue: aiPolishMode) ?? .automatic
    }

    var body: some View {
        SettingsCard(icon: "wand.and.stars", title: "ai.polish.title".localized) {
            VStack(alignment: .leading, spacing: 16) {
                statusBanner

                if isGoogleConfigured {
                    connectedActions
                } else {
                    setupGuide
                }

                Divider()

                controls
                footerText
            }
        }
        .onAppear(perform: refreshState)
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGoogleConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isGoogleConfigured ? Color.sapoGreen : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(isGoogleConfigured ? "ai.google_connected".localized : "ai.google_missing".localized)
                    .font(.subheadline)
                    .fontWeight(.semibold)

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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("ai.polish.enable".localized, isOn: aiPolishBinding)
                .disabled(!isGoogleConfigured)

            Picker("ai.polish.mode".localized, selection: $aiPolishMode) {
                ForEach(TranscriptPolishMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            .disabled(!isGoogleConfigured || !aiPolishEnabled)

            Text("ai.polish.mode_desc".localized(currentMode.displayName))
                .font(.caption)
                .foregroundStyle(.secondary)
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
        HStack(spacing: 8) {
            Button {
                detectGoogleCredentials()
            } label: {
                Label("ai.google_detect_adc".localized, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                importGoogleCredentials()
            } label: {
                Label("ai.google_change_json".localized, systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)

            Button("config.service_account_remove".localized, role: .destructive) {
                ServiceAccountManager.shared.remove()
                aiPolishEnabled = false
                refreshState()
            }
            .buttonStyle(.bordered)
        }
    }

    private var footerText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ai.polish.desc".localized)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let connectionMessage {
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
        .frame(width: 480)
        .padding()
}
