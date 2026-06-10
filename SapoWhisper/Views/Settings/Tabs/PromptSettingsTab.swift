//
//  PromptSettingsTab.swift
//  SapoWhisper
//

import SwiftUI

struct PromptSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AIPolishSettingsCard()
                PromptContextSettingsCard()
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }
}

private struct PromptContextSettingsCard: View {
    @ObservedObject private var promptManager = PromptContextManager.shared
    @Namespace private var profileSelection

    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var aiPolishOutputLanguage =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    @State private var selectedPromptID: String?
    @State private var personalDetails = ""
    @State private var isPersonalContextExpanded = false
    @State private var draftName = ""
    @State private var draftDetails = ""
    @State private var draftInstruction = ""
    @State private var draftForcesEnglish = false
    @State private var selectionBounce = 0
    @State private var isEffectivePromptExpanded = false
    @State private var isPreviewPolishExpanded = false
    @State private var previewSample = "prompts.preview_sample".localized
    @State private var previewState: PolishPreviewState = .idle
    @State private var feedbackMessage: String?

    private enum PolishPreviewState: Equatable {
        case idle
        case running
        case result(String)
        case failure(String)
    }

    private static let personalContextLimit = 2_000

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

    private var effectiveSystemPrompt: String {
        TranscriptPolishPromptBuilder.makeMessages(
            rawText: "",
            promptProfile: draftProfile,
            personalContext: promptManager.personalContext.details,
            outputLanguage: draftOutputLanguage,
            keyterms: VocabularyManager.shared.keyterms,
            replacements: VocabularyManager.shared.replacements
        ).system
    }

    private var isProviderConfigured: Bool {
        OpenAICompatiblePolisher().isConfigured
    }

    var body: some View {
        SettingsCard(icon: "text.badge.star", title: "prompts.title".localized) {
            VStack(alignment: .leading, spacing: 18) {
                personalContextSection
                Divider()
                promptProfilesSection
                Divider()
                effectivePromptSection
                Divider()
                previewPolishSection

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            loadPersonalContext()
            isPersonalContextExpanded = personalDetails.isEmpty
            selectInitialPromptIfNeeded()
        }
        .onChange(of: selectedPromptID) { _, _ in
            loadSelectedPrompt()
        }
    }

    // MARK: - Personal context

    private var personalContextSection: some View {
        DisclosureGroup(isExpanded: $isPersonalContextExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                paddedTextEditor(text: $personalDetails, minHeight: 120)

                HStack(spacing: 10) {
                    Text("prompts.personal_context_hint".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    Spacer()
                    Text("\(personalDetails.count)/\(Self.personalContextLimit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(
                            personalDetails.count > Self.personalContextLimit ? Color.sapoError : .secondary
                        )
                    Button("prompts.save_context".localized, action: savePersonalContext)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } label: {
            sectionHeader(
                title: "prompts.personal_context".localized,
                subtitle: "prompts.personal_context_desc".localized
            )
        }
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    // MARK: - Profiles

    private var promptProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
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
                    Text(prompt.trimmedName)
                        .font(.subheadline)
                        .lineLimit(1)
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

            paddedTextEditor(text: $draftInstruction, minHeight: 130)

            HStack {
                Text("prompts.instruction_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("prompts.delete_prompt".localized, action: deletePrompt)
                    .buttonStyle(.bordered)
                    .disabled(promptManager.prompts.count <= 1)
                Button("prompts.save_prompt".localized, action: savePrompt)
                    .buttonStyle(.borderedProminent)
                    .tint(Constants.Colors.sapoGreen)
                    .disabled(
                        draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draftInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Effective prompt

    private var effectivePromptSection: some View {
        DisclosureGroup(isExpanded: $isEffectivePromptExpanded) {
            ScrollView {
                Text(effectiveSystemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18))
            )
            .padding(.top, 8)
        } label: {
            sectionHeader(
                title: "prompts.effective_prompt".localized,
                subtitle: "prompts.effective_prompt_desc".localized
            )
        }
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    // MARK: - Preview polish

    private var previewPolishSection: some View {
        DisclosureGroup(isExpanded: $isPreviewPolishExpanded) {
            previewPolishContent
                .padding(.top, 8)
        } label: {
            sectionHeader(
                title: "prompts.preview_polish".localized,
                subtitle: "prompts.preview_polish_desc".localized
            )
        }
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    private var previewPolishContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            paddedTextEditor(text: $previewSample, minHeight: 54)

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

    // MARK: - Shared helpers

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadPersonalContext() {
        personalDetails = promptManager.personalContext.details
    }

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

    private func savePersonalContext() {
        promptManager.updatePersonalContext(details: personalDetails)
        feedbackMessage = "prompts.context_saved".localized
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

    @ViewBuilder
    private func paddedTextEditor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18))
            )
    }
}

/// Disclosure style where the whole header row toggles the group — clicking
/// the title or the subtitle works, not just the chevron.
private struct ClickableDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))

                    configuration.label

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

#Preview("Prompt Settings") {
    PromptSettingsTab()
        .frame(width: 780, height: 720)
}
