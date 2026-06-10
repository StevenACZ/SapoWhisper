//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import SwiftUI
import os

/// AI polish settings: one OpenAI-compatible provider (OpenRouter by default),
/// an API key stored in the Keychain, a model, and the polish behavior pickers.
/// Paste a key, press Test, done — no cloud-project setup anywhere.
struct AIPolishSettingsCard: View {
    @ObservedObject private var promptContextManager = PromptContextManager.shared

    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishMode = TranscriptPolishMode.automatic.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishMinimumDuration) private var aiPolishMinimumDuration =
        TranscriptPolishMinimumDuration.defaultPolicy.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishEndpoint) private var endpointValue = PolishEndpoint.default.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishModel) private var model = PolishEndpoint.default.defaultModel
    @AppStorage(Constants.StorageKeys.aiPolishCustomBaseURL) private var customBaseURL = ""
    @AppStorage(Constants.StorageKeys.language) private var transcriptionLanguage = "auto"

    @State private var apiKey = ""
    @State private var keychainReadDenied = false
    @State private var testState: ProviderTestState = .idle
    @State private var isProviderExpanded = false
    /// The keychain is only read once the provider section actually expands,
    /// so opening Settings never touches the keychain (guardrail: gate on
    /// `hasValue` hints, never `string(for:)`, in launch/settings paths).
    @State private var hasLoadedAPIKey = false

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    private var isProviderUsable: Bool {
        if hasLoadedAPIKey {
            return PolishProviderConfiguration.isUsable(
                endpoint: endpoint,
                model: model,
                customBaseURL: customBaseURL,
                apiKey: apiKey
            )
        }
        return PolishProviderConfiguration.hasUsableConfiguration()
    }

    private var currentPrompt: PromptProfile {
        promptContextManager.promptProfile(for: aiPolishMode)
    }

    private var currentOutputLanguage: TranscriptPolishOutputLanguage {
        if currentPrompt.forcesEnglish {
            return .english
        }
        return TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
    }

    private var currentMinimumDuration: TranscriptPolishMinimumDuration {
        TranscriptPolishMinimumDuration(rawValue: aiPolishMinimumDuration) ?? .defaultPolicy
    }

    private var activeSubtitle: String {
        switch currentMinimumDuration {
        case .always:
            return "ai.polish.enable_active_always".localized
        case .seconds20, .seconds30:
            return "ai.polish.enable_active_after".localized(currentMinimumDuration.displayName)
        }
    }

    var body: some View {
        SettingsCard(icon: "sparkles", title: "ai.polish.title".localized) {
            VStack(alignment: .leading, spacing: 12) {
                AIPolishHeroToggle(
                    isOn: $aiPolishEnabled,
                    activeSubtitle: activeSubtitle
                )

                // With the hero toggle off nothing below is in effect, so the
                // whole configuration reads (and is) inert.
                AIPolishProviderSection(
                    endpointValue: $endpointValue,
                    model: $model,
                    customBaseURL: $customBaseURL,
                    apiKey: $apiKey,
                    keychainReadDenied: $keychainReadDenied,
                    testState: $testState,
                    isExpanded: $isProviderExpanded,
                    isProviderUsable: isProviderUsable,
                    onWillExpand: loadAPIKeyIfNeeded
                )
                .disabled(!aiPolishEnabled)
                .opacity(aiPolishEnabled ? 1 : 0.62)

                if aiPolishEnabled && !isProviderUsable {
                    Label("ai.provider.needs_key".localized, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                }

                Divider()

                // The three behavior pickers share one row — they are small
                // menus, stacking them only added scrolling. fixedSize makes
                // the row take its ideal (tallest-tile) height so the
                // maxHeight: .infinity tiles equalize instead of expanding.
                HStack(alignment: .top, spacing: 8) {
                    modePicker
                    outputLanguagePicker
                    minimumDurationPicker
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(aiPolishEnabled ? 1 : 0.62)
            }
            .animation(.smooth(duration: 0.2), value: aiPolishEnabled)
        }
        .onAppear {
            // Start collapsed when the provider already works; expand (and
            // only then read the keychain) when setup is still pending.
            isProviderExpanded = !PolishProviderConfiguration.hasUsableConfiguration()
            if isProviderExpanded {
                loadAPIKeyIfNeeded()
            }
            // The curated-catalog picker needs a valid selection to render
            if endpoint.suggestedModels.isEmpty == false,
                model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                model = endpoint.defaultModel
            }
        }
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.setString(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .aiPolishAPIKey)
            testState = .idle
        }
        .onChange(of: endpointValue) { oldValue, _ in
            let previous = PolishEndpoint(rawValue: oldValue) ?? .default
            if model.isEmpty || model == previous.defaultModel {
                model = endpoint.defaultModel
            }
            testState = .idle
        }
        .onChange(of: model) { _, _ in
            testState = .idle
        }
        .onChange(of: aiPolishOutputLanguage) { _, _ in
            syncTranscriptionLanguageWithTranslation()
        }
        .onChange(of: aiPolishMode) { _, _ in
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
        guard !hasLoadedAPIKey else { return }
        hasLoadedAPIKey = true
        apiKey = KeychainStore.string(for: .aiPolishAPIKey) ?? ""
        keychainReadDenied = KeychainStore.isReadDenied
    }

    // MARK: - Behavior

    private var modePicker: some View {
        AIPolishSettingRow(
            title: "ai.polish.mode".localized,
            detail: "ai.polish.mode_desc".localized(currentPrompt.trimmedName)
        ) {
            Picker("ai.polish.mode".localized, selection: $aiPolishMode) {
                ForEach(promptContextManager.prompts) { prompt in
                    Text(prompt.trimmedName).tag(prompt.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!aiPolishEnabled)
        }
    }

    private var outputLanguagePicker: some View {
        AIPolishSettingRow(
            title: "ai.polish.output_language".localized,
            detail: currentOutputLanguage.requiresTranslation
                ? "ai.polish.output_language_translation_desc".localized(currentOutputLanguage.displayName)
                : "ai.polish.output_language_desc".localized(currentOutputLanguage.displayName)
        ) {
            if currentPrompt.forcesEnglish {
                FixedValuePill(text: currentOutputLanguage.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("ai.polish.output_language".localized, selection: $aiPolishOutputLanguage) {
                    ForEach(TranscriptPolishOutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!aiPolishEnabled)
            }
        }
    }

    private var minimumDurationPicker: some View {
        let policy = TranscriptPolishMinimumDuration(rawValue: aiPolishMinimumDuration) ?? .defaultPolicy

        return AIPolishSettingRow(
            title: "ai.polish.minimum_duration".localized,
            detail: policy.description
        ) {
            Picker("ai.polish.minimum_duration".localized, selection: $aiPolishMinimumDuration) {
                ForEach(TranscriptPolishMinimumDuration.allCases) { policy in
                    Text(policy.displayName).tag(policy.rawValue)
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
