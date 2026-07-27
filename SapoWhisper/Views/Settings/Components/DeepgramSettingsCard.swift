import SwiftUI

struct DeepgramSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @State private var deepgramAPIKey = ""
    @State private var keychainReadDenied = false
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedMode = DeepgramTranscriptionMode.nova3.rawValue

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
    }

    private var currentMode: DeepgramTranscriptionMode {
        DeepgramTranscriptionMode(rawValue: selectedMode) ?? .nova3
    }

    var body: some View {
        Group {
            if isEmbedded {
                cardContent
            } else {
                SettingsCard(icon: "waveform.badge.mic", title: "Deepgram") {
                    cardContent
                }
            }
        }
        .onChange(of: deepgramAPIKey) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (KeychainStore.string(for: .deepgramAPIKey) ?? "") else { return }
            KeychainStore.setString(trimmed, for: .deepgramAPIKey)
            viewModel.setEngine(.deepgram)
        }
        .onAppear {
            deepgramAPIKey = KeychainStore.string(for: .deepgramAPIKey) ?? ""
            keychainReadDenied = KeychainStore.isReadDenied
            viewModel.setDeepgramMode(currentMode)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSelector

            Divider()

            apiKeyStatus

            if keychainReadDenied {
                KeychainAccessRetryNotice {
                    deepgramAPIKey = KeychainStore.string(for: .deepgramAPIKey) ?? ""
                    keychainReadDenied = KeychainStore.isReadDenied
                }
            }

            SecureField("config.deepgram_key_placeholder".localized, text: $deepgramAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(keychainReadDenied)

            Text("config.deepgram_key_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.deepgram_mode".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                ForEach(DeepgramTranscriptionMode.allCases) { mode in
                    EngineModeButton(
                        icon: mode.icon,
                        title: mode.displayName,
                        subtitle: mode.description,
                        isSelected: currentMode == mode
                    ) {
                        withAnimation(Constants.Animation.reveal) {
                            selectedMode = mode.rawValue
                            viewModel.setDeepgramMode(mode)
                        }
                    }
                }
            }
        }
    }

    private var apiKeyStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: deepgramAPIKey.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(deepgramAPIKey.isEmpty ? .orange : .sapoGreen)
            Text(deepgramAPIKey.isEmpty ? "config.deepgram_key_missing".localized : "config.deepgram_key_configured".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
