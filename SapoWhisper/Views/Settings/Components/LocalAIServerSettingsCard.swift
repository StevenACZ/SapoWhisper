//
//  LocalAIServerSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct LocalAIServerSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.localAIServerBaseURL) private var baseURL = ""
    @AppStorage(Constants.StorageKeys.localAIServerModel) private var model = LocalAIServerConfiguration.defaultModel

    @State private var apiKey = ""
    @State private var keychainReadDenied = false
    @State private var testState: TestState = .idle

    init(viewModel: SapoWhisperViewModel, isEmbedded: Bool = false) {
        self.viewModel = viewModel
        self.isEmbedded = isEmbedded
    }

    var body: some View {
        Group {
            if isEmbedded {
                cardContent
            } else {
                SettingsCard(icon: TranscriptionEngine.localAIServer.icon, title: TranscriptionEngine.localAIServer.displayName) {
                    cardContent
                }
            }
        }
        .onAppear {
            apiKey = KeychainStore.string(for: .localAIServerAPIKey) ?? ""
            keychainReadDenied = KeychainStore.isReadDenied
        }
        .onChange(of: baseURL) { _, _ in
            testState = .idle
            viewModel.setEngine(.localAIServer)
        }
        .onChange(of: model) { _, _ in
            testState = .idle
            viewModel.setEngine(.localAIServer)
        }
        .onChange(of: apiKey) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (KeychainStore.string(for: .localAIServerAPIKey) ?? "") else { return }
            KeychainStore.setString(trimmed, for: .localAIServerAPIKey)
            viewModel.setEngine(.localAIServer)
            testState = .idle
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow

            VStack(alignment: .leading, spacing: 6) {
                Text("config.local_ai_base_url".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("config.local_ai_base_url_placeholder".localized, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("config.local_ai_model".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Menu("config.local_ai_model_suggestions".localized) {
                        ForEach(LocalAIServerConfiguration.suggestedModels, id: \.self) { suggestedModel in
                            Button(suggestedModel) {
                                model = suggestedModel
                            }
                        }
                    }
                    .font(.caption)
                    .menuStyle(.borderlessButton)
                }

                TextField("config.local_ai_model_placeholder".localized, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if keychainReadDenied {
                KeychainAccessRetryNotice {
                    apiKey = KeychainStore.string(for: .localAIServerAPIKey) ?? ""
                    keychainReadDenied = KeychainStore.isReadDenied
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("config.local_ai_api_key".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("config.local_ai_api_key_placeholder".localized, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("config.local_ai_api_key_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: testConnection) {
                    Label("config.local_ai_test".localized, systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(!canTest || testState == .running)

                testStateView
                Spacer()
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: canTest ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(canTest ? .sapoGreen : .orange)
            Text(canTest ? "config.local_ai_configured".localized : "config.local_ai_missing".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var testStateView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView()
                .controlSize(.small)
        case .success(let modelAvailable):
            Label(
                modelAvailable ? "config.local_ai_test_success".localized : "config.local_ai_test_model_unlisted".localized,
                systemImage: modelAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(modelAvailable ? Color.sapoGreenText : Color.orange)
            .lineLimit(2)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.sapoError)
                .lineLimit(2)
        }
    }

    private var canTest: Bool {
        LocalAIServerConfiguration.normalizedBaseURL(from: baseURL) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func testConnection() {
        testState = .running
        let baseURL = baseURL
        let model = model
        let apiKey = apiKey
        Task { @MainActor in
            do {
                let result = try await viewModel.localAIServerTranscriber.testConnection(
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                )
                testState = .success(modelAvailable: result.modelAvailable)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private enum TestState: Equatable {
        case idle
        case running
        case success(modelAvailable: Bool)
        case failure(String)
    }
}

#Preview("Local AI Server Settings") {
    LocalAIServerSettingsCard(viewModel: SapoWhisperViewModel())
        .padding()
        .frame(width: 460)
}
