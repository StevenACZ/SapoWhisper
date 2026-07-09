//
//  PromptContextSettingsCard.swift
//  SapoWhisper
//

import SwiftUI

/// Personal context: one optional free-text block that disambiguates the
/// user's tools and terms. Prompt profiles were removed — the polish prompt is
/// a single adaptive contract. The live polish preview lives in the AI polish
/// card, next to the provider/mode controls it exercises.
struct PromptContextSettingsCard: View {
    private var promptManager = PromptContextManager.shared

    @State private var draftContext = ""
    @State private var showsSavedConfirmation = false
    @State private var savedConfirmationTask: Task<Void, Never>?

    private var hasUnsavedChanges: Bool {
        draftContext != promptManager.personalContext.details
    }

    var body: some View {
        SettingsCard(icon: "person.text.rectangle", title: "prompts.personal_context".localized) {
            personalContextSection
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
                        .foregroundStyle(Color.sapoGreenText)
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
            .animation(Constants.Animation.reveal, value: hasUnsavedChanges)
            .animation(Constants.Animation.reveal, value: showsSavedConfirmation)
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
            withAnimation(Constants.Animation.transition) {
                showsSavedConfirmation = false
            }
        }
    }

}
