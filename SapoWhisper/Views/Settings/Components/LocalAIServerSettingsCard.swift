//
//  LocalAIServerSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

struct LocalAIServerSettingsCard: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    let isEmbedded: Bool

    @AppStorage(Constants.StorageKeys.localAIServerBaseURL, store: AppPreferences.defaults) private var baseURL = ""
    @AppStorage(Constants.StorageKeys.localAIServerModel, store: AppPreferences.defaults) private var model = LocalAIServerConfiguration
        .defaultModel

    @State private var apiKey = ""
    @State private var keychainReadDenied = false
    @State private var testTask: Task<Void, Never>?
    @State private var testGeneration: UInt64 = 0
    @State private var testObservation: EngineReachabilityLog.Observation?

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
        .onDisappear { resetConnectionTest() }
        .onChange(of: apiKey) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != (KeychainStore.string(for: .localAIServerAPIKey) ?? "") else { return }
            KeychainStore.setString(trimmed, for: .localAIServerAPIKey)
            viewModel.setEngine(.localAIServer)
            resetConnectionTest()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusRow

            VStack(alignment: .leading, spacing: 6) {
                Text("config.local_ai_base_url".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("config.local_ai_base_url_placeholder".localized, text: baseURLBinding)
                    .accessibilityIdentifier("local-server-url")
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
                                modelBinding.wrappedValue = suggestedModel
                            }
                        }
                    }
                    .font(.caption)
                    .menuStyle(.borderlessButton)
                }

                TextField("config.local_ai_model_placeholder".localized, text: modelBinding)
                    .accessibilityIdentifier("local-server-model")
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
                    .disabled(keychainReadDenied)
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
                .disabled(!canTest || viewModel.localAIServerConnectionState == .checking)
                .accessibilityIdentifier("local-server-test")

                testStateView
                Spacer()
            }
            Text("config.local_ai_test_scope".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: statusPresentation.icon)
                .foregroundStyle(statusPresentation.color)
            Text(statusPresentation.title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusPresentation: (icon: String, title: String, color: Color) {
        guard canTest else { return ("xmark.circle.fill", "config.local_ai_missing".localized, .orange) }
        switch viewModel.localAIServerConnectionState {
        case .unchecked:
            return ("questionmark.circle", "config.local_ai_unchecked".localized, .secondary)
        case .checking:
            return ("arrow.triangle.2.circlepath", "config.local_ai_checking".localized, .secondary)
        case .reachable:
            return ("network", "config.local_ai_reachable".localized, .secondary)
        case .transcribed:
            return ("checkmark.circle.fill", "config.local_ai_transcribed".localized, .sapoGreen)
        case .verified(let modelAvailable):
            return (
                modelAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                modelAvailable ? "config.local_ai_verified".localized : "config.local_ai_model_unverified".localized,
                modelAvailable ? .sapoGreen : .orange
            )
        case .failed:
            return ("exclamationmark.triangle.fill", "config.local_ai_last_failed".localized, .orange)
        }
    }

    @ViewBuilder
    private var testStateView: some View {
        switch viewModel.localAIServerConnectionState {
        case .unchecked, .reachable, .transcribed:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .verified(let modelAvailable):
            Label(
                modelAvailable ? "config.local_ai_test_success".localized : "config.local_ai_test_model_unlisted".localized,
                systemImage: modelAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(modelAvailable ? Color.sapoGreenText : Color.orange)
            .lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.sapoError)
                .lineLimit(2)
        }
    }

    private var canTest: Bool {
        LocalAIServerConfiguration.normalizedBaseURL(from: baseURL, apiKey: apiKey) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { baseURL },
            set: {
                resetConnectionTest()
                viewModel.updateLocalAIServerSettings(baseURL: $0)
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { model },
            set: {
                resetConnectionTest()
                viewModel.updateLocalAIServerSettings(model: $0)
            }
        )
    }

    private func resetConnectionTest() {
        testTask?.cancel()
        testTask = nil
        testGeneration &+= 1
        if let testObservation { viewModel.cancelLocalAIServerConnectionTest(testObservation) }
        testObservation = nil
    }

    private func testConnection() {
        resetConnectionTest()
        let generation = testGeneration
        let baseURL = baseURL
        let model = model
        let apiKey = apiKey
        let observation = viewModel.beginLocalAIServerConnectionTest()
        testObservation = observation
        testTask = Task { @MainActor in
            do {
                let result = try await viewModel.localAIServerTranscriber.testConnection(
                    baseURL: baseURL,
                    model: model,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, generation == testGeneration,
                    baseURL == self.baseURL, model == self.model, apiKey == self.apiKey
                else { return }
                viewModel.completeLocalAIServerConnectionTest(observation, modelAvailable: result.modelAvailable)
                testTask = nil
                testObservation = nil
            } catch {
                guard !Task.isCancelled, generation == testGeneration,
                    baseURL == self.baseURL, model == self.model, apiKey == self.apiKey
                else { return }
                viewModel.failLocalAIServerConnectionTest(observation, error: error)
                testTask = nil
                testObservation = nil
            }
        }
    }

}

#Preview("Local AI Server Settings") {
    LocalAIServerSettingsCard(viewModel: SapoWhisperViewModel())
        .padding()
        .frame(width: 460)
}
