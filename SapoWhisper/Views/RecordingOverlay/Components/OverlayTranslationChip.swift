//
//  OverlayTranslationChip.swift
//  SapoWhisper
//

import SwiftUI

/// Translation chip shown in the recording and completed pills. It writes
/// straight to the shared AppStorage key, so a selection is sticky: it applies
/// to this dictation and every following one until changed. Polishing itself
/// has no modes — the single adaptive prompt handles every text type.
struct OverlayTranslationChip: View {
    /// Fired after the output-language default is updated.
    var onTranslationToggled: ((Bool) -> Void)?

    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false
    @AppStorage(Constants.StorageKeys.aiPolishOutputLanguage) private var outputLanguageValue =
        TranscriptPolishOutputLanguage.sameAsInput.rawValue

    private var outputLanguage: TranscriptPolishOutputLanguage {
        TranscriptPolishOutputLanguage(rawValue: outputLanguageValue) ?? .sameAsInput
    }

    var body: some View {
        if aiPolishEnabled {
            translationChip
        }
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
