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
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishModeValue = PolishMode.default.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishMinDuration) private var aiPolishMinDurationValue =
        PolishMinimumDuration.always.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishEndpoint) private var endpointValue = PolishEndpoint.default.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishReasoningEffort) private var reasoningEffortValue =
        PolishReasoningEffort.default.rawValue
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

    private var currentMode: PolishMode {
        PolishMode(rawValue: aiPolishModeValue) ?? .default
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

                modeRow
                    .opacity(aiPolishEnabled ? 1 : 0.62)

                Divider()

                minDurationRow
                    .opacity(aiPolishEnabled ? 1 : 0.62)

                Divider()

                outputLanguageRow
                    .opacity(aiPolishEnabled ? 1 : 0.62)

                Divider()

                reasoningEffortRow
                    .opacity(aiPolishEnabled ? 1 : 0.62)

                Divider()

                // Right under the knobs it exercises: switch model, style, or
                // reasoning and verify the result without leaving the card.
                PolishPreviewSection()
                    .disabled(!aiPolishEnabled)
                    .opacity(aiPolishEnabled ? 1 : 0.62)
            }
            .animation(Constants.Animation.reveal, value: aiPolishEnabled)
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

    // MARK: - Polish mode

    /// Normal cleans the dictation; Compact rewrites it as the shortest
    /// faithful text. Each option carries its own hover help, and the caption
    /// always describes the selected mode.
    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("ai.polish.mode".localized)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    ForEach(PolishMode.allCases) { mode in
                        Button {
                            aiPolishModeValue = mode.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                if mode == .compact {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                Text(mode.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundColor(currentMode == mode ? .white : .primary)
                            .background(
                                Capsule().fill(
                                    currentMode == mode
                                        ? (mode == .compact ? Color.compactMode : Color.aiPolish)
                                        : Color.primary.opacity(0.08)
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(mode.helpText)
                        .disabled(!aiPolishEnabled)
                    }
                }
            }

            Text(currentMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if currentMode == .compact {
                Label("ai.polish.mode_compact_hint".localized, systemImage: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(Color.compactMode)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Constants.Animation.reveal, value: currentMode)
    }

    // MARK: - Minimum duration

    /// User-chosen live-dictation length below which the polish is skipped
    /// (both styles): a 5-second snippet gains nothing from an AI round-trip.
    /// Manual re-polish from History always runs.
    private var minDurationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("ai.polish.min_duration".localized)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Picker("ai.polish.min_duration".localized, selection: $aiPolishMinDurationValue) {
                    ForEach(PolishMinimumDuration.allCases) { threshold in
                        Text(threshold.displayName).tag(threshold.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!aiPolishEnabled)
            }

            Text("ai.polish.min_duration_desc".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Output language

    /// Single inline row: the picker already names the current value, so the
    /// only extra copy is the translation note when a target is picked.
    private var outputLanguageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("ai.polish.output_language".localized)
                    .font(.subheadline.weight(.semibold))

                AIPolishFidelityBadge()

                Spacer(minLength: 8)

                Picker("ai.polish.output_language".localized, selection: $aiPolishOutputLanguage) {
                    ForEach(TranscriptPolishOutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!aiPolishEnabled)
            }

            if currentOutputLanguage.requiresTranslation {
                Label(
                    "ai.polish.output_language_translation_desc".localized(currentOutputLanguage.displayName),
                    systemImage: "globe"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Constants.Animation.reveal, value: currentOutputLanguage.requiresTranslation)
    }

    // MARK: - Reasoning effort

    /// Global reasoning budget applied to every polish request regardless of
    /// endpoint or model. Off by default: reasoning models otherwise think
    /// away the output token budget (and the latency budget) of a polish.
    private var reasoningEffortRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("ai.polish.reasoning".localized)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Picker("ai.polish.reasoning".localized, selection: $reasoningEffortValue) {
                    ForEach(PolishReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!aiPolishEnabled)
            }

            Text("ai.polish.reasoning_desc".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
