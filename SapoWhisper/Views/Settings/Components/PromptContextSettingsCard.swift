//
//  PromptContextSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

/// Personal context, prompt profiles (master-detail editor), the effective
/// system prompt preview, and the live polish preview.
struct PromptContextSettingsCard: View {
    @ObservedObject private var promptManager = PromptContextManager.shared
    @Namespace private var profileSelection

    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    @State private var selectedPromptID: String?
    @State private var draftName = ""
    @State private var draftDetails = ""
    @State private var draftInstruction = ""
    @State private var draftForcesEnglish = false
    @State private var selectionBounce = 0
    @State private var isPreviewPolishExpanded = false
    @State private var previewSample = "prompts.preview_sample".localized
    @State private var previewState: PolishPreviewState = .idle
    @State private var feedbackMessage: String?
    @State private var isDeleteConfirmationPresented = false

    private enum PolishPreviewState: Equatable {
        case idle
        case running
        case result(String)
        case failure(String)
    }

    private var selectedPrompt: PromptProfile {
        promptManager.promptProfile(for: selectedPromptID)
    }

    /// The profile as currently drafted in the editor, so the effective-prompt
    /// preview and the polish preview reflect unsaved edits live.
    private var draftProfile: PromptProfile {
        PromptProfile(
            id: selectedPrompt.id,
            name: draftName,
            details: draftDetails,
            instruction: draftInstruction,
            forcesEnglish: draftForcesEnglish
        )
    }

    private var draftOutputLanguage: TranscriptPolishOutputLanguage {
        if draftForcesEnglish {
            return .english
        }
        return TranscriptPolishOutputLanguage(rawValue: aiPolishOutputLanguage) ?? .sameAsInput
    }

    private var isProviderConfigured: Bool {
        OpenAICompatiblePolisher().isConfigured
    }

    /// Switching profiles still discards edits silently (no modal friction);
    /// the unsaved dot is what makes that risk visible beforehand.
    private var hasUnsavedChanges: Bool {
        let saved = selectedPrompt
        return draftName != saved.name
            || draftDetails != saved.details
            || draftInstruction != saved.instruction
            || draftForcesEnglish != saved.forcesEnglish
    }

    var body: some View {
        SettingsCard(icon: "text.badge.star", title: "prompts.title".localized) {
            VStack(alignment: .leading, spacing: 18) {
                promptProfilesSection
                Divider()
                previewPolishSection

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: selectInitialPromptIfNeeded)
        .onChange(of: selectedPromptID) { _, _ in
            loadSelectedPrompt()
        }
    }

    // MARK: - Profiles

    private var promptProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(
                title: "prompts.project_prompts".localized,
                subtitle: "prompts.project_prompts_desc".localized
            )

            HStack(alignment: .top, spacing: 14) {
                promptList
                    .frame(width: 220)

                Divider()

                promptEditor
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var promptList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(promptManager.prompts) { prompt in
                promptRow(prompt)
            }

            HStack(spacing: 6) {
                Button(action: addPrompt) {
                    Label("prompts.add_prompt".localized, systemImage: "plus")
                }
                Button(action: duplicatePrompt) {
                    Label("prompts.duplicate_prompt".localized, systemImage: "plus.square.on.square")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private func promptRow(_ prompt: PromptProfile) -> some View {
        let isSelected = prompt.id == selectedPromptID
        return Button {
            withAnimation(.smooth(duration: 0.28)) {
                selectedPromptID = prompt.id
            }
            selectionBounce += 1
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: profileIcon(for: prompt))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.sapoGreen : .secondary)
                    .symbolEffect(.bounce, value: isSelected ? selectionBounce : 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(prompt.trimmedName)
                            .font(.subheadline)
                            .lineLimit(1)

                        if isSelected && hasUnsavedChanges {
                            Circle()
                                .fill(Color.sapoGreen)
                                .frame(width: 6, height: 6)
                                .transition(.scale.combined(with: .opacity))
                                .help("prompts.unsaved_changes".localized)
                        }
                    }
                    Text(prompt.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.sapoGreen.opacity(0.16))
                        .matchedGeometryEffect(id: "prompt-selection", in: profileSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func profileIcon(for prompt: PromptProfile) -> String {
        switch prompt.id {
        case TranscriptPolishMode.automatic.rawValue:
            return "wand.and.stars"
        case TranscriptPolishMode.ai.rawValue:
            return "cpu"
        case TranscriptPolishMode.work.rawValue:
            return "briefcase"
        case TranscriptPolishMode.translateEnglish.rawValue:
            return "translate"
        default:
            return prompt.forcesEnglish ? "translate" : "text.alignleft"
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("prompts.name".localized, text: $draftName)
                .textFieldStyle(.roundedBorder)

            TextField("prompts.description".localized, text: $draftDetails)
                .textFieldStyle(.roundedBorder)

            Toggle("prompts.force_english".localized, isOn: $draftForcesEnglish)
                .font(.caption)

            Label("prompts.base_rules_note".localized, systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsTextEditor(text: $draftInstruction, minHeight: 130)

            HStack(spacing: 8) {
                Text("prompts.instruction_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()

                if hasUnsavedChanges {
                    Circle()
                        .fill(Color.sapoGreen)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                        .help("prompts.unsaved_changes".localized)
                }

                Button("prompts.delete_prompt".localized) {
                    isDeleteConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .disabled(promptManager.prompts.count <= 1)
                Button("prompts.save_prompt".localized, action: savePrompt)
                    .buttonStyle(.borderedProminent)
                    .tint(Constants.Colors.sapoGreen)
                    .disabled(
                        !hasUnsavedChanges
                            || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .animation(.smooth(duration: 0.2), value: hasUnsavedChanges)
        }
        .confirmationDialog(
            "prompts.delete_confirm_title".localized(selectedPrompt.trimmedName),
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("prompts.delete_confirm_action".localized, role: .destructive, action: deletePrompt)
        } message: {
            Text("prompts.delete_confirm_message".localized)
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
            promptProfile: draftProfile,
            personalContext: promptManager.personalContext.details,
            outputLanguage: draftOutputLanguage,
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

    // MARK: - Actions

    private func selectInitialPromptIfNeeded() {
        if selectedPromptID == nil {
            selectedPromptID = promptManager.prompts.first?.id
        }
        loadSelectedPrompt()
    }

    private func loadSelectedPrompt() {
        let prompt = selectedPrompt
        draftName = prompt.name
        draftDetails = prompt.details
        draftInstruction = prompt.instruction
        draftForcesEnglish = prompt.forcesEnglish
    }

    private func addPrompt() {
        let prompt = PromptProfile(
            id: UUID().uuidString.lowercased(),
            name: "New Prompt",
            details: "Custom dictation mode",
            instruction: "Polish the transcript while preserving the user's exact intent.",
            forcesEnglish: false
        )
        promptManager.upsertPrompt(prompt)
        withAnimation(.smooth(duration: 0.28)) {
            selectedPromptID = prompt.id
        }
    }

    private func duplicatePrompt() {
        let source = selectedPrompt
        let copy = PromptProfile(
            id: UUID().uuidString.lowercased(),
            name: String("\(source.trimmedName) copy".prefix(60)),
            details: source.details,
            instruction: source.instruction,
            forcesEnglish: source.forcesEnglish
        )
        promptManager.upsertPrompt(copy)
        withAnimation(.smooth(duration: 0.28)) {
            selectedPromptID = copy.id
        }
        selectionBounce += 1
        feedbackMessage = "prompts.prompt_duplicated".localized
    }

    private func savePrompt() {
        let prompt = PromptProfile(
            id: selectedPrompt.id,
            name: draftName,
            details: draftDetails,
            instruction: draftInstruction,
            forcesEnglish: draftForcesEnglish
        )
        promptManager.upsertPrompt(prompt)
        selectedPromptID = prompt.id
        feedbackMessage = "prompts.prompt_saved".localized
    }

    private func deletePrompt() {
        let id = selectedPrompt.id
        promptManager.removePrompt(id: id)
        withAnimation(.smooth(duration: 0.28)) {
            selectedPromptID = promptManager.prompts.first?.id
        }
        feedbackMessage = "prompts.prompt_deleted".localized
    }
}
