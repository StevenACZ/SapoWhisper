import SwiftUI

struct DeepgramSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel

    @AppStorage(Constants.StorageKeys.deepgramAPIKey) private var deepgramAPIKey = ""
    @AppStorage(Constants.StorageKeys.deepgramTranscriptionMode) private var selectedMode = DeepgramTranscriptionMode.nova3.rawValue

    private var currentMode: DeepgramTranscriptionMode {
        DeepgramTranscriptionMode(rawValue: selectedMode) ?? .nova3
    }

    var body: some View {
        SettingsCard(icon: "waveform.badge.mic", title: "Deepgram") {
            VStack(alignment: .leading, spacing: 16) {
                modeSelector

                Divider()

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
        .onAppear {
            viewModel.setDeepgramMode(currentMode)
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.deepgram_mode".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                ForEach(DeepgramTranscriptionMode.allCases) { mode in
                    DeepgramModeButton(
                        mode: mode,
                        isSelected: currentMode == mode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
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

private struct DeepgramModeButton: View {
    let mode: DeepgramTranscriptionMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(mode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary.opacity(0.5))
            }
            .padding(10)
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
