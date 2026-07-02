//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import SwiftUI
import os

/// AI polish settings: one OpenAI-compatible provider (OpenRouter by default),
/// an API key stored in the Keychain, a model, and the output language.
/// Paste a key, press Test, done — the single adaptive prompt handles the
/// rest, so there are no mode or duration pickers.
struct AIPolishSettingsCard: View {
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishEndpoint) private var endpointValue = PolishEndpoint.default.rawValue
    @AppStorage(Constants.StorageKeys.language) private var transcriptionLanguage = "auto"

    @State private var model = PolishEndpoint.default.defaultModel
    @State private var baseURL = PolishEndpoint.default.defaultBaseURL
    @State private var apiKey = ""
    @State private var keychainReadDenied = false
    @State private var testState: ProviderTestState = .idle
    @State private var isProviderExpanded = false
    @State private var showsOptionalAPIKey = false
    @State private var isLoadingProviderFields = false
    /// The keychain is only read once the provider section actually expands,
    /// so opening Settings never touches the keychain (guardrail: gate on
    /// `hasValue` hints, never `string(for:)`, in launch/settings paths).
    @State private var hasLoadedAPIKey = false

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    private var isProviderUsable: Bool {
        let effectiveAPIKey =
            hasLoadedAPIKey
            ? apiKey
            : (PolishProviderConfiguration.hasAPIKeyHint(for: endpoint) ? "stored" : "")
        return PolishProviderConfiguration.isUsable(
            endpoint: endpoint,
            model: model,
            customBaseURL: baseURL,
            apiKey: effectiveAPIKey
        )
    }

    private var currentOutputLanguage: TranscriptPolishOutputLanguage {
        TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
    }

    private var outputLanguageOptions: [TranscriptPolishOutputLanguage] {
        return TranscriptPolishOutputLanguage.allCases
    }

    var body: some View {
        SettingsCard(icon: "sparkles", title: "ai.polish.title".localized) {
            VStack(alignment: .leading, spacing: 12) {
                AIPolishHeroToggle(
                    isOn: $aiPolishEnabled,
                    activeSubtitle: "ai.polish.enable_active_always".localized
                )

                // With the hero toggle off nothing below is in effect, so the
                // whole configuration reads (and is) inert.
                AIPolishProviderSection(
                    endpointValue: $endpointValue,
                    model: $model,
                    baseURL: $baseURL,
                    apiKey: $apiKey,
                    keychainReadDenied: $keychainReadDenied,
                    testState: $testState,
                    isExpanded: $isProviderExpanded,
                    showsOptionalAPIKey: $showsOptionalAPIKey,
                    isProviderUsable: isProviderUsable,
                    hasStoredAPIKey: PolishProviderConfiguration.hasAPIKeyHint(for: endpoint),
                    onWillExpand: loadAPIKeyIfNeeded,
                    onWillEditAPIKey: loadAPIKeyForEditing
                )
                .disabled(!aiPolishEnabled)
                .opacity(aiPolishEnabled ? 1 : 0.62)

                if aiPolishEnabled && !isProviderUsable {
                    Label("ai.provider.needs_key".localized, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                }

                Divider()

                outputLanguagePicker
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(aiPolishEnabled ? 1 : 0.62)
            }
            .animation(.smooth(duration: 0.2), value: aiPolishEnabled)
        }
        .onAppear {
            // Start collapsed when the provider already works; expand (and
            // only then read the keychain) when setup is still pending.
            loadProviderFields(allowLegacyFallback: true, readAPIKey: false)
            isProviderExpanded = !PolishProviderConfiguration.hasUsableConfiguration()
            if isProviderExpanded {
                loadAPIKeyIfNeeded()
            }
        }
        .onChange(of: apiKey) { _, newValue in
            guard !isLoadingProviderFields else { return }
            guard hasLoadedAPIKey || endpoint.showsAPIKeyByDefault || showsOptionalAPIKey else { return }
            KeychainStore.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: endpoint.apiKeychainKey)
            testState = .idle
        }
        .onChange(of: endpointValue) { oldValue, _ in
            let previous = PolishEndpoint(rawValue: oldValue) ?? .default
            loadProviderFields(allowLegacyFallback: false, readAPIKey: isProviderExpanded && endpoint.showsAPIKeyByDefault)
            showsOptionalAPIKey = false
            if previous != endpoint {
                keychainReadDenied = false
            }
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
        .onChange(of: aiPolishOutputLanguage) { _, _ in
            syncTranscriptionLanguageWithTranslation()
        }
        .onChange(of: aiPolishEnabled) { _, _ in
            syncTranscriptionLanguageWithTranslation()
        }
    }

    /// Engines never translate — a pinned recognition language makes them
    /// mis-transcribe any other spoken language, which then feeds the
    /// translator garbage. The moment AI translation becomes active the
    /// spoken language is unknown, so reset the hint to auto-detect; the
    /// user can still re-pin a language afterwards.
    private func syncTranscriptionLanguageWithTranslation() {
        guard aiPolishEnabled, currentOutputLanguage.requiresTranslation, transcriptionLanguage != "auto" else {
            return
        }
        transcriptionLanguage = "auto"
        SapoLog.settings.info(
            "Transcription language reset to auto reason=ai-translation target=\(currentOutputLanguage.rawValue, privacy: .public)"
        )
    }

    private func loadAPIKeyIfNeeded() {
        guard !hasLoadedAPIKey, endpoint.showsAPIKeyByDefault else { return }
        loadAPIKeyForEditing()
    }

    private func loadAPIKeyForEditing() {
        guard !hasLoadedAPIKey || keychainReadDenied else { return }
        hasLoadedAPIKey = true
        apiKey = PolishProviderConfiguration.apiKey(for: endpoint, allowLegacyFallback: true)
        if !apiKey.isEmpty, !KeychainStore.hasValue(for: endpoint.apiKeychainKey) {
            KeychainStore.setString(apiKey, for: endpoint.apiKeychainKey)
        }
        keychainReadDenied = KeychainStore.isReadDenied
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
        hasLoadedAPIKey = false
        apiKey = ""
        if readAPIKey {
            loadAPIKeyForEditing()
        }
        DispatchQueue.main.async {
            isLoadingProviderFields = false
        }
    }

    // MARK: - Behavior

    private var outputLanguagePicker: some View {
        AIPolishSettingRow(
            title: "ai.polish.output_language".localized,
            detail: currentOutputLanguage.requiresTranslation
                ? "ai.polish.output_language_translation_desc".localized(currentOutputLanguage.displayName)
                : "ai.polish.output_language_desc".localized(currentOutputLanguage.displayName)
        ) {
            Picker("ai.polish.output_language".localized, selection: $aiPolishOutputLanguage) {
                ForEach(outputLanguageOptions) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!aiPolishEnabled)
        } footer: {
            AIPolishFidelityBadge()
        }
    }
}

enum ProviderTestState: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)
}

#Preview("AI Polish Settings") {
    AIPolishSettingsCard()
        .frame(width: 400)
        .padding()
}
