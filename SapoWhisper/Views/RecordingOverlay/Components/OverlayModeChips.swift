//
//  OverlayModeChips.swift
//  SapoWhisper
//

import SwiftUI

/// Quick mode + translation chips shown in the recording and completed pills.
/// Chips write straight to the shared AppStorage keys, so a selection is
/// sticky: it applies to this dictation and every following one until changed.
struct OverlayModeChips: View {
    /// Fired after the mode default is updated (chip tapped).
    var onModeSelected: ((String) -> Void)?
    /// Fired after the output-language default is updated (translation chip).
    var onTranslationToggled: ((Bool) -> Void)?

    @ObservedObject private var promptManager = PromptContextManager.shared
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishMode) private var aiPolishMode = TranscriptPolishMode.automatic.rawValue
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var outputLanguageValue =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    /// Only pinned profiles (max 3, configured in Settings → Prompts) appear
    /// as chips; the full catalog stays reachable from the menu bar picker.
    /// No chip active = the base clean-up mode.
    private var visiblePrompts: [PromptProfile] {
        promptManager.quickChipPrompts
    }

    private var outputLanguage: TranscriptPolishOutputLanguage {
        TranscriptPolishOutputLanguage(rawValue: outputLanguageValue) ?? .sameAsInput
    }

    var body: some View {
        if aiPolishEnabled {
            // A plain row: with at most 3 pinned chips plus the translation
            // chip everything fits in one line, and it avoids the measured
            // wrap layout whose height could disagree with placement.
            HStack(spacing: 5) {
                ForEach(visiblePrompts) { prompt in
                    modeChip(for: prompt)
                }

                translationChip
            }
        }
    }

    private func modeChip(for prompt: PromptProfile) -> some View {
        let isSelected = prompt.id == aiPolishMode
        return Button {
            if isSelected {
                // Chips toggle: deselecting falls back to the base clean-up
                // mode, so "no special mode" needs no chip of its own.
                aiPolishMode = TranscriptPolishMode.automatic.rawValue
                onModeSelected?(aiPolishMode)
                return
            }
            aiPolishMode = prompt.id
            // Choosing a mode means "polish from now on": lift the
            // minimum-duration gate so the very next dictation uses it.
            TranscriptPolishMinimumDuration.promoteToAlwaysForSelectedMode(prompt.id)
            // A translation profile with no target language is a no-op the
            // user cannot see coming — picking it turns the shared output
            // language on (last target, English by default).
            if prompt.isTranslationProfile, !outputLanguage.requiresTranslation {
                activateQuickTranslationTarget()
            }
            onModeSelected?(prompt.id)
        } label: {
            Text(prompt.trimmedName)
                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 84)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(isSelected ? .sapoGreen : .primary.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? Color.sapoGreen.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.sapoGreen.opacity(0.55) : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .help(prompt.details)
    }

    /// Toggles between "same as audio" and the last explicit target language
    /// (English until the user picks another one in Settings or the menu bar).
    private var translationChip: some View {
        let isActive = outputLanguage.requiresTranslation
        let label = isActive ? chipLabel(for: outputLanguage) : "overlay.lang_auto".localized
        return Button {
            toggleTranslation()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isActive ? .aiPolish : .primary.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Color.aiPolish.opacity(0.16) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(isActive ? Color.aiPolish.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("ai.polish.output_language".localized)
    }

    private func chipLabel(for language: TranscriptPolishOutputLanguage) -> String {
        language.nlLanguageCode?.uppercased() ?? "overlay.lang_auto".localized
    }

    private func toggleTranslation() {
        if outputLanguage.requiresTranslation {
            // Remember the target so the chip can restore it on the next tap.
            UserDefaults.standard.set(
                outputLanguageValue,
                forKey: Constants.StorageKeys.aiPolishQuickTranslationTarget
            )
            outputLanguageValue = TranscriptPolishOutputLanguage.sameAsInput.rawValue
            onTranslationToggled?(false)
        } else {
            activateQuickTranslationTarget()
            onTranslationToggled?(true)
        }
    }

    private func activateQuickTranslationTarget() {
        let stored = UserDefaults.standard.string(forKey: Constants.StorageKeys.aiPolishQuickTranslationTarget)
        let target = stored.flatMap { TranscriptPolishOutputLanguage(rawValue: $0) } ?? .english
        let resolved = target.requiresTranslation ? target : .english
        outputLanguageValue = resolved.rawValue
    }
}
