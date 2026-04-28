import SwiftUI

struct DeepgramSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.deepgramAPIKey) private var deepgramAPIKey = ""

    var body: some View {
        SettingsCard(icon: "waveform.badge.mic", title: "Deepgram") {
            VStack(alignment: .leading, spacing: 12) {
                apiKeyStatus

                SecureField("config.deepgram_key_placeholder".localized, text: $deepgramAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("config.deepgram_key_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: deepgramAPIKey) { _, _ in
            viewModel.setEngine(.deepgram)
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
