//
//  AIPolishSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

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

    @State private var apiKey = ""
    @State private var testState: ProviderTestState = .idle

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    private var isProviderUsable: Bool {
        PolishProviderConfiguration.isUsable(
            endpoint: endpoint,
            model: model,
            customBaseURL: customBaseURL,
            apiKey: apiKey
        )
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

                providerSection

                if aiPolishEnabled && !isProviderUsable {
                    Label("ai.provider.needs_key".localized, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(Color.sapoError)
                }

                Divider()

                // The three behavior pickers share one row — they are small
                // menus, stacking them only added scrolling.
                HStack(alignment: .top, spacing: 12) {
                    modePicker
                    outputLanguagePicker
                    minimumDurationPicker
                }
                .opacity(aiPolishEnabled ? 1 : 0.62)

                AIPolishInfoCallout(
                    title: "ai.polish.fidelity_info_title".localized,
                    detail: "ai.polish.desc".localized
                )
            }
        }
        .onAppear {
            apiKey = KeychainStore.string(for: .aiPolishAPIKey) ?? ""
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
    }

    // MARK: - Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ai.provider.section".localized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            Picker("ai.provider.endpoint".localized, selection: $endpointValue) {
                ForEach(PolishEndpoint.allCases) { endpoint in
                    Text(endpoint.displayName).tag(endpoint.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if endpoint == .custom {
                TextField("ai.provider.custom_url_placeholder".localized, text: $customBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Model and key side by side: the whole provider setup fits in
            // one glance instead of a long stack.
            HStack(alignment: .top, spacing: 12) {
                modelRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                apiKeyRow
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            testRow
        }
        .animation(.smooth(duration: 0.25), value: endpoint)
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ai.provider.model".localized)
                .font(.subheadline)

            HStack(spacing: 6) {
                TextField("ai.provider.model_placeholder".localized, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                if !endpoint.suggestedModels.isEmpty {
                    Menu {
                        ForEach(endpoint.suggestedModels, id: \.self) { suggestion in
                            Button(suggestion) { model = suggestion }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ai.provider.api_key".localized)
                .font(.subheadline)

            SecureField("ai.provider.api_key_placeholder".localized, text: $apiKey)
                .textFieldStyle(.roundedBorder)

            Text("ai.provider.api_key_hint".localized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var testRow: some View {
        HStack(spacing: 8) {
            Button(action: runTest) {
                Label("ai.provider.test".localized, systemImage: "bolt.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isProviderUsable || testState == .running)

            switch testState {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .success(let modelIdentifier):
                Label("ai.provider.test_success".localized(modelIdentifier), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.sapoGreen)
                    .symbolEffect(.bounce, value: testState)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.sapoError)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
    }

    private func runTest() {
        testState = .running
        Task { @MainActor in
            do {
                let response = try await OpenAICompatiblePolisher().runConnectionTest()
                testState = .success(response.modelIdentifier)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
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
            detail: "ai.polish.output_language_desc".localized(currentOutputLanguage.displayName)
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
        }
    }
}

enum ProviderTestState: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)
}

private struct AIPolishSettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)

            control()

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FixedValuePill: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AIPolishInfoCallout: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.sapoGreen)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.sapoGreen)
                    .textCase(.uppercase)
                    .tracking(0.3)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sapoGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.sapoGreen.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct AIPolishHeroToggle: View {
    @Binding var isOn: Bool
    let activeSubtitle: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 34, height: 34)
                    .shadow(color: isOn ? Color.sapoGreen.opacity(0.35) : .clear, radius: 4, y: 1)

                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("ai.polish.enable".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(isOn ? activeSubtitle : "ai.polish.enable_subtitle".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.sapoGreen)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.sapoGreen.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn ? Color.sapoGreen.opacity(0.38) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }

    private var iconBackground: LinearGradient {
        if isOn {
            return LinearGradient(
                colors: [Color.purple, Color.sapoGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.secondary.opacity(0.22), Color.secondary.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview("AI Polish Settings") {
    AIPolishSettingsCard()
        .frame(width: 400)
        .padding()
}
