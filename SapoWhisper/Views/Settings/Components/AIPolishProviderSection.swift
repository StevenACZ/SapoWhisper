//
//  AIPolishProviderSection.swift
//  SapoWhisper
//

import SwiftUI

/// Provider configuration (endpoint, model, API key, connection test) that
/// collapses into a one-line summary once it is usable, so the day-to-day
/// Prompts view leads with the toggle, behavior pickers, and prompt list.
struct AIPolishProviderSection: View {
    @Binding var endpointValue: String
    @Binding var model: String
    @Binding var customBaseURL: String
    @Binding var apiKey: String
    @Binding var keychainReadDenied: Bool
    @Binding var testState: ProviderTestState
    @Binding var isExpanded: Bool
    let isProviderUsable: Bool
    /// Called before the section expands, so the keychain read can stay lazy.
    let onWillExpand: () -> Void

    private var endpoint: PolishEndpoint {
        PolishEndpoint(rawValue: endpointValue) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExpanded {
                expandedSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                summaryRow
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: isExpanded)
    }

    // MARK: - Collapsed summary

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Group {
                Text(endpoint.displayName)
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(model)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)

            if isProviderUsable {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.sapoGreen)
                    .help("ai.provider.summary_key_help".localized)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("ai.provider.needs_key".localized)
            }

            Spacer(minLength: 8)

            Button("ai.provider.summary_edit".localized) {
                onWillExpand()
                withAnimation(.smooth(duration: 0.25)) {
                    isExpanded = true
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Expanded configuration

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ai.provider.section".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Spacer(minLength: 8)

                if isProviderUsable {
                    Button("ai.provider.summary_done".localized) {
                        withAnimation(.smooth(duration: 0.25)) {
                            isExpanded = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.sapoGreen)
                }
            }

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

            // Model and key side by side; both columns are just label +
            // control so they stay the same height — the keychain notice and
            // the hints live below at full width instead of bloating one side.
            HStack(alignment: .top, spacing: 12) {
                modelRow
                    .frame(maxWidth: .infinity, alignment: .leading)
                apiKeyRow
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if keychainReadDenied {
                KeychainAccessRetryNotice {
                    apiKey = KeychainStore.string(for: .aiPolishAPIKey) ?? ""
                    keychainReadDenied = KeychainStore.isReadDenied
                }
            }

            HStack(alignment: .top, spacing: 12) {
                Group {
                    if endpoint == .openRouter {
                        Text("ai.provider.model_custom_hint".localized)
                    } else {
                        Text(" ")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("ai.provider.api_key_hint".localized)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            testRow
        }
        .animation(.smooth(duration: 0.25), value: endpoint)
    }

    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ai.provider.model".localized)
                .font(.subheadline)

            PolishModelPicker(endpoint: endpoint, model: $model)
        }
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ai.provider.api_key".localized)
                .font(.subheadline)

            SecureField("ai.provider.api_key_placeholder".localized, text: $apiKey)
                .textFieldStyle(.roundedBorder)
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
                // A passing test means the provider is set up; tuck the
                // configuration away after a beat so the result stays legible.
                try? await Task.sleep(for: .seconds(1.2))
                if case .success = testState {
                    withAnimation(.smooth(duration: 0.25)) {
                        isExpanded = false
                    }
                }
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
