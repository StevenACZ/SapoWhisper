import SwiftUI

struct WelcomeAIPolishStep: View {
    @AppStorage(Constants.StorageKeys.aiPolishEnabled, store: AppPreferences.defaults) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishEndpoint, store: AppPreferences.defaults) private var endpointValue = PolishEndpoint.default
        .rawValue

    @State private var model = PolishEndpoint.default.defaultModel
    @State private var baseURL = PolishEndpoint.default.defaultBaseURL
    @State private var apiKey = ""
    @State private var testState: ProviderTestState = .idle
    @State private var showsOptionalAPIKey = false
    @State private var isLoadingProviderFields = false
    @State private var keychainReadDenied = false

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomeStepTitle(
                title: "welcome.ai_title".localized,
                subtitle: "welcome.ai_subtitle".localized
            )

            VStack(alignment: .leading, spacing: 12) {
                Picker("ai.provider.endpoint".localized, selection: $endpointValue) {
                    ForEach(PolishEndpoint.allCases) { endpoint in
                        Text(endpoint.displayName).tag(endpoint.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if endpoint.usesEditableBaseURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.base_url".localized)
                            .font(.subheadline)
                        TextField("ai.provider.custom_url_placeholder".localized, text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ai.provider.model".localized)
                            .font(.subheadline)
                        PolishModelPicker(endpoint: endpoint, model: $model)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if shouldShowAPIKeyRow {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                endpoint.requiresAPIKey
                                    ? "ai.provider.api_key".localized : "ai.provider.api_key_optional".localized
                            )
                            .font(.subheadline)
                            SecureField("ai.provider.api_key_placeholder".localized, text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .disabled(keychainReadDenied)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if keychainReadDenied {
                    KeychainAccessRetryNotice {
                        loadAPIKeyForEditing()
                    }
                }

                if endpoint == .localServer, !shouldShowAPIKeyRow {
                    Button {
                        loadAPIKeyForEditing()
                        showsOptionalAPIKey = true
                    } label: {
                        Label("ai.provider.optional_key_show".localized, systemImage: "key")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(action: runTest) {
                        Label("ai.provider.test".localized, systemImage: "bolt.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isUsable || testState == .running)

                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView()
                            .controlSize(.small)
                    case .success(let identifier):
                        Label("ai.provider.test_success".localized(identifier), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.sapoGreenText)
                            .symbolEffect(.bounce, value: testState)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .failure(let message):
                        Label {
                            Text(message)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(message)
                    }

                    Spacer()
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            Label("welcome.ai_footnote".localized, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .onAppear {
            loadProviderFields(allowLegacyFallback: true, readAPIKey: endpoint.showsAPIKeyByDefault)
        }
        .onChange(of: apiKey) { _, newValue in
            guard !isLoadingProviderFields else { return }
            guard endpoint.showsAPIKeyByDefault || showsOptionalAPIKey else { return }
            keychainReadDenied = !EngineKeyValidator.persist(key: newValue, for: endpoint.apiKeychainKey)
            testState = .idle
        }
        .onChange(of: endpointValue) { _, _ in
            loadProviderFields(allowLegacyFallback: false, readAPIKey: endpoint.showsAPIKeyByDefault)
            showsOptionalAPIKey = false
            keychainReadDenied = false
            testState = .idle
        }
        .onChange(of: model) { _, newValue in
            PolishProviderConfiguration.setStoredModel(newValue, for: endpoint)
            testState = .idle
        }
        .onChange(of: baseURL) { _, newValue in
            PolishProviderConfiguration.setStoredBaseURLInput(newValue, for: endpoint)
            testState = .idle
        }
        .animation(Constants.Animation.reveal, value: endpoint)
    }

    private var shouldShowAPIKeyRow: Bool {
        endpoint.showsAPIKeyByDefault || showsOptionalAPIKey
    }

    private var isUsable: Bool {
        let effectiveAPIKey =
            endpoint.showsAPIKeyByDefault || showsOptionalAPIKey
            ? apiKey
            : (PolishProviderConfiguration.hasAPIKeyHint(for: endpoint) ? "stored" : "")
        return PolishProviderConfiguration.isUsable(
            endpoint: endpoint,
            model: model,
            customBaseURL: baseURL,
            apiKey: effectiveAPIKey
        )
    }

    private func runTest() {
        testState = .running
        Task { @MainActor in
            do {
                let response = try await OpenAICompatiblePolisher().runConnectionTest()
                testState = .success(response.modelIdentifier)
                aiPolishEnabled = true
            } catch {
                testState = .failure(PolishProviderError.connectionTestMessage(for: error, endpoint: endpoint))
            }
        }
    }

    private func loadProviderFields(allowLegacyFallback: Bool, readAPIKey: Bool) {
        isLoadingProviderFields = true
        model = PolishProviderConfiguration.storedModel(
            for: endpoint,
            allowLegacyFallback: allowLegacyFallback
        )
        baseURL = PolishProviderConfiguration.storedBaseURLInput(
            for: endpoint,
            allowLegacyFallback: allowLegacyFallback
        )
        apiKey = ""
        if readAPIKey {
            loadAPIKeyForEditing()
        }
        DispatchQueue.main.async {
            isLoadingProviderFields = false
        }
    }

    private func loadAPIKeyForEditing() {
        apiKey = PolishProviderConfiguration.apiKey(for: endpoint, allowLegacyFallback: true)
        if !apiKey.isEmpty, !KeychainStore.hasValue(for: endpoint.apiKeychainKey) {
            _ = EngineKeyValidator.persist(key: apiKey, for: endpoint.apiKeychainKey)
        }
        keychainReadDenied = KeychainStore.isReadDenied
    }
}
