//
//  PromptContextSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

/// Personal context (one optional free-text block that disambiguates the
/// user's tools and terms) plus the live polish preview. Prompt profiles were
/// removed — the polish prompt is a single adaptive contract.
struct PromptContextSettingsCard: View {
    private var promptManager = PromptContextManager.shared

    @State private var draftContext = ""
    @State private var isPreviewPolishExpanded = false
    @State private var previewSample = "prompts.preview_sample".localized
    @State private var previewState: PolishPreviewState = .idle
    @State private var showsSavedConfirmation = false
    @State private var savedConfirmationTask: Task<Void, Never>?

    private enum PolishPreviewState: Equatable {
        case idle
        case running
        case result(String)
        case failure(String)
    }

    private var isProviderConfigured: Bool {
        OpenAICompatiblePolisher().isConfigured
    }

    private var hasUnsavedChanges: Bool {
        draftContext != promptManager.personalContext.details
    }

    var body: some View {
        SettingsCard(icon: "person.text.rectangle", title: "prompts.personal_context".localized) {
            VStack(alignment: .leading, spacing: 12) {
                personalContextSection
                Divider()
                previewPolishSection
            }
        }
        .onAppear {
            draftContext = promptManager.personalContext.details
        }
    }

    // MARK: - Personal context

    private var personalContextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("prompts.personal_context_desc".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsTextEditor(text: $draftContext, minHeight: 96)

            HStack(spacing: 8) {
                Text("prompts.personal_context_hint".localized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 8)

                if showsSavedConfirmation {
                    Label("prompts.prompt_saved".localized, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.sapoGreen)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if hasUnsavedChanges {
                    Circle()
                        .fill(Color.sapoGreen)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                        .help("prompts.unsaved_changes".localized)
                }

                Button("prompts.save_prompt".localized, action: saveContext)
                    .buttonStyle(.borderedProminent)
                    .tint(Constants.Colors.sapoGreen)
                    .disabled(!hasUnsavedChanges)
            }
            .animation(.smooth(duration: 0.2), value: hasUnsavedChanges)
            .animation(.smooth(duration: 0.2), value: showsSavedConfirmation)
        }
    }

    private func saveContext() {
        promptManager.updatePersonalContext(details: draftContext)
        draftContext = promptManager.personalContext.details
        savedConfirmationTask?.cancel()
        showsSavedConfirmation = true
        savedConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) {
                showsSavedConfirmation = false
            }
        }
    }

    // MARK: - Preview polish

    private var previewPolishSection: some View {
        DisclosureGroup(isExpanded: $isPreviewPolishExpanded) {
            previewPolishContent
                .padding(.top, 8)
        } label: {
            SettingsSectionHeader(
                title: "prompts.preview_polish".localized,
                subtitle: "prompts.preview_polish_desc".localized
            )
        }
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    private var previewPolishContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsTextEditor(text: $previewSample, minHeight: 54)

            HStack(spacing: 8) {
                Button(action: runPolishPreview) {
                    Label("prompts.preview_run".localized, systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    !isProviderConfigured || previewState == .running
                        || previewSample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if previewState == .running {
                    ProgressView()
                        .controlSize(.small)
                }

                if !isProviderConfigured {
                    Label("prompts.preview_needs_provider".localized, systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            switch previewState {
            case .result(let polished):
                HStack(alignment: .top, spacing: 10) {
                    previewColumn(
                        title: "prompts.preview_raw".localized,
                        text: previewSample,
                        accent: .secondary
                    )
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 22)
                    previewColumn(
                        title: "prompts.preview_polished".localized,
                        text: polished,
                        accent: Color.sapoGreen
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .failure(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.sapoError)
                    .lineLimit(2)
            case .idle, .running:
                EmptyView()
            }
        }
        .animation(.smooth(duration: 0.25), value: previewState)
    }

    private func previewColumn(title: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
                .textCase(.uppercase)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.08))
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func runPolishPreview() {
        let sample = previewSample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return }
        previewState = .running

        let messages = TranscriptPolishPromptBuilder.makeMessages(
            rawText: sample,
            personalContext: draftContext,
            outputLanguage: TranscriptPostProcessor.configuredOutputLanguage(),
            keyterms: VocabularyManager.shared.keyterms,
            replacements: VocabularyManager.shared.replacements
        )

        Task { @MainActor in
            do {
                let response = try await OpenAICompatiblePolisher().polish(
                    system: messages.system,
                    user: messages.user,
                    timeout: 12
                )
                let cleaned = PolishOutputSanitizer.clean(response.text, rawText: sample)
                previewState = .result(cleaned.isEmpty ? response.text : cleaned)
            } catch {
                previewState = .failure(error.localizedDescription)
            }
        }
    }
}
