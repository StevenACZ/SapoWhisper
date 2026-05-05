import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GoogleCloudSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.googleCloudAPIKey) private var googleCloudAPIKey = ""
    @State private var showAPIKeySection = false
    @State private var serviceAccountError: String?

    var body: some View {
        SettingsCard(icon: "cloud", title: "Google Cloud") {
            VStack(alignment: .leading, spacing: 12) {
                recordingLimitWarning
                serviceAccountSection
                Divider()
                apiKeyFallbackSection
            }
        }
    }

    private var recordingLimitWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text("config.google_60s_warning".localized)
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var serviceAccountSection: some View {
        if ServiceAccountManager.shared.isConfigured {
            configuredServiceAccountView
        } else {
            missingServiceAccountView
        }

        if let error = serviceAccountError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private var configuredServiceAccountView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.sapoGreen)
                Text("config.service_account_configured".localized("Chirp 3"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Button("config.service_account_change".localized) { importServiceAccount() }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                    .font(.caption)

                Button("config.service_account_remove".localized) {
                    ServiceAccountManager.shared.remove()
                    viewModel.setEngine(.googleCloud)
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.caption)
            }
        }
    }

    private var missingServiceAccountView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.service_account_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button(action: { importServiceAccount() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("config.service_account_import".localized)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button(action: detectServiceAccount) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("config.service_account_detect".localized)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var apiKeyFallbackSection: some View {
        DisclosureGroup(
            isExpanded: $showAPIKeySection,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: googleCloudAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(googleCloudAPIKey.isEmpty ? .orange : .sapoGreen)
                        Text(googleCloudAPIKey.isEmpty ? "config.api_key_missing".localized : "config.api_key_configured".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    SecureField("config.api_key_placeholder".localized, text: $googleCloudAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("config.api_key_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.secondary)
                    Text("config.api_key_fallback".localized)
                        .font(.subheadline)
                }
            }
        )
    }

    private func detectServiceAccount() {
        ServiceAccountManager.shared.reload()
        serviceAccountError = nil
        viewModel.setEngine(.googleCloud)
    }

    private func importServiceAccount() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "config.service_account_desc".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ServiceAccountManager.shared.importFile(from: url)
            serviceAccountError = nil
            viewModel.setEngine(.googleCloud)
        } catch {
            serviceAccountError = error.localizedDescription
        }
    }
}
