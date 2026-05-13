//
//  PromptSettingsTab.swift
//  SapoWhisper
//

import SwiftUI

struct PromptSettingsTab: View {
    var body: some View {
        ScrollView {
            PromptContextSettingsCard()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
    }
}

private struct PromptContextSettingsCard: View {
    @ObservedObject private var promptManager = PromptContextManager.shared

    @State private var selectedPromptID: String?
    @State private var personalDetails = ""
    @State private var draftName = ""
    @State private var draftDetails = ""
    @State private var draftInstruction = ""
    @State private var draftForcesEnglish = false
    @State private var feedbackMessage: String?

    private var selectedPrompt: PromptProfile {
        promptManager.promptProfile(for: selectedPromptID)
    }

    var body: some View {
        SettingsCard(icon: "text.badge.star", title: "prompts.title".localized) {
            VStack(alignment: .leading, spacing: 18) {
                personalContextSection
                Divider()
                promptProfilesSection

                if let feedbackMessage {
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            loadPersonalContext()
            selectInitialPromptIfNeeded()
        }
        .onChange(of: selectedPromptID) { _, _ in
            loadSelectedPrompt()
        }
    }

    private var personalContextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "prompts.personal_context".localized,
                subtitle: "prompts.personal_context_desc".localized
            )

            paddedTextEditor(text: $personalDetails, minHeight: 180)

            HStack {
                Text("prompts.personal_context_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("prompts.save_context".localized, action: savePersonalContext)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var promptProfilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                title: "prompts.project_prompts".localized,
                subtitle: "prompts.project_prompts_desc".localized
            )

            HStack(alignment: .top, spacing: 14) {
                promptList
                    .frame(width: 210)

                Divider()

                promptEditor
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var promptList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(promptManager.prompts) { prompt in
                Button {
                    selectedPromptID = prompt.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: prompt.forcesEnglish ? "translate" : "text.alignleft")
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.trimmedName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(prompt.details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(prompt.id == selectedPromptID ? Color.sapoGreen.opacity(0.16) : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Button(action: addPrompt) {
                Label("prompts.add_prompt".localized, systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        selectedPromptID = prompt.id
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
        selectedPromptID = promptManager.prompts.first?.id
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

#Preview("Prompt Settings") {
    PromptSettingsTab()
        .frame(width: 780, height: 560)
}
