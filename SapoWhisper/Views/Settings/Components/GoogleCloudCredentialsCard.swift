//
//  GoogleCloudCredentialsCard.swift
//  SapoWhisper
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Shared observable state for the Google Cloud credentials so both the credentials
/// card and the AI polish card react to detect/import/remove from a single source.
final class GoogleCredentialsState: ObservableObject {
    @Published private(set) var isConfigured: Bool
    @Published private(set) var projectID: String?
    @Published var connectionMessage: String?

    init() {
        let manager = ServiceAccountManager.shared
        self.isConfigured = manager.isConfigured
        self.projectID = manager.projectID
    }

    func refresh() {
        let manager = ServiceAccountManager.shared
        isConfigured = manager.isConfigured
        projectID = manager.projectID
    }

    func detectADC() {
        ServiceAccountManager.shared.reload()
        refresh()
        connectionMessage = isConfigured ? nil : "ai.google_not_detected".localized
    }

    func importFile(from url: URL) {
        do {
            try ServiceAccountManager.shared.importFile(from: url)
            connectionMessage = nil
        } catch {
            connectionMessage = error.localizedDescription
        }
        refresh()
    }

    func remove() {
        ServiceAccountManager.shared.remove()
        connectionMessage = nil
        refresh()
    }
}

/// Card that owns the Google Cloud credential lifecycle: detect / import / remove
/// plus the setup guide when no credentials are present. Designed to sit in the
/// left settings column under the transcription engine list.
struct GoogleCloudCredentialsCard: View {
    @ObservedObject var credentials: GoogleCredentialsState

    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false

    var body: some View {
        SettingsCard(icon: "cloud.fill", title: "ai.google_credentials.title".localized) {
            VStack(alignment: .leading, spacing: 14) {
                statusBanner

                credentialScopePills

                if !credentials.isConfigured {
                    Divider()
                    setupGuide
                }

                if let message = credentials.connectionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onAppear { credentials.refresh() }
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            GoogleCloudIcon(size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(credentials.isConfigured ? "ai.google_connected".localized : "ai.google_missing".localized)
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Image(systemName: credentials.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(credentials.isConfigured ? Color.sapoGreen : .orange)
                }

                Text(credentials.isConfigured ? "ai.google_connected_desc".localized : "ai.google_missing_desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let projectID = credentials.projectID {
                    Text(projectID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var credentialScopePills: some View {
        HStack(spacing: 6) {
            CredentialScopePill(icon: "waveform", text: "Chirp 3", tint: .blue)
            CredentialScopePill(icon: "sparkles", text: "Vertex AI", tint: .purple)

            if credentials.isConfigured {
                Spacer(minLength: 8)
                connectedActions
            }
        }
    }

    private var connectedActions: some View {
        HStack(spacing: 6) {
            detectButton
            changeButton
            removeButton
        }
    }

    private var detectButton: some View {
        Button {
            credentials.detectADC()
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
            credentials.remove()
            aiPolishEnabled = false
        } label: {
            Label("config.service_account_remove".localized, systemImage: "trash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ai.google_setup_intro".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CredentialSetupStep(
                number: 1,
                title: "ai.google_step1_title".localized,
                detail: "ai.google_step1_detail".localized,
                command: "brew install google-cloud-sdk"
            )

            CredentialSetupStep(
                number: 2,
                title: "ai.google_step2_title".localized,
                detail: "ai.google_step2_detail".localized,
                command: "gcloud auth application-default login"
            )

            CredentialSetupStep(
                number: 3,
                title: "ai.google_step3_title".localized,
                detail: "ai.google_step3_detail".localized
            )

            HStack(spacing: 8) {
                Button {
                    credentials.detectADC()
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

    private func importGoogleCredentials() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "ai.google_import_panel_desc".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        credentials.importFile(from: url)
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

private struct CredentialScopePill: View {
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

private struct CredentialSetupStep: View {
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

#Preview("Google Cloud Credentials — Configured") {
    GoogleCloudCredentialsCard(credentials: GoogleCredentialsState())
        .frame(width: 500)
        .padding()
}
