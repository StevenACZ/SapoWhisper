//
//  PolishPreviewSection.swift
//  SapoWhisper
//

import SwiftUI

/// Live polish tester that sits right under the provider/mode/reasoning
/// controls so switching model or Normal/Compact can be verified on the spot.
/// Runs the real provider with the prompt of the CURRENTLY selected mode and
/// the saved personal context — exactly what a dictation would get.
struct PolishPreviewSection: View {
    @State private var isExpanded = false
    @State private var sample = "prompts.preview_sample".localized
    @State private var state: PreviewState = .idle

    private enum PreviewState: Equatable {
        case idle
        case running
        case result(text: String, mode: PolishMode)
        case failure(String)
    }

    private var isProviderConfigured: Bool {
        OpenAICompatiblePolisher().isConfigured
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 8)
        } label: {
            SettingsSectionHeader(
                title: "prompts.preview_polish".localized,
                subtitle: "prompts.preview_polish_desc".localized
            )
        }
        .disclosureGroupStyle(ClickableDisclosureStyle())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsTextEditor(text: $sample, minHeight: 54)

            HStack(spacing: 8) {
                Button(action: run) {
                    Label("prompts.preview_run".localized, systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    !isProviderConfigured || state == .running
                        || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if state == .running {
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

            switch state {
            case .result(let polished, let mode):
                HStack(alignment: .top, spacing: 10) {
                    column(
                        title: "prompts.preview_raw".localized,
                        text: sample,
                        accent: .secondary
                    )
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 22)
                    column(
                        title: polishedTitle(for: mode),
                        text: polished,
                        accent: mode == .compact ? Color.compactMode : Color.sapoGreen,
                        badge: trimBadge(for: polished, mode: mode)
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
        .animation(Constants.Animation.reveal, value: state)
    }

    private func polishedTitle(for mode: PolishMode) -> String {
        "\("prompts.preview_polished".localized) · \(mode.displayName)"
    }

    /// Compact's whole promise is the trim, so the result carries the same
    /// −N% the copied toast shows after a real dictation.
    private func trimBadge(for polished: String, mode: PolishMode) -> String? {
        guard mode == .compact, !sample.isEmpty else { return nil }
        let percent = 100 - Int((Double(polished.count) / Double(sample.count)) * 100)
        return percent > 0 ? "−\(percent)%" : nil
    }

    private func column(title: String, text: String, accent: Color, badge: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                    .textCase(.uppercase)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(Color.compactMode)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.compactMode.opacity(0.16)))
                }
            }
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

    private func run() {
        let raw = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        state = .running

        let mode = PolishMode.current()
        let personalContext = PromptContextManager.shared.personalContext.details
        let outputLanguage = TranscriptPostProcessor.configuredOutputLanguage()
        let keyterms = VocabularyManager.shared.keyterms
        let replacements = VocabularyManager.shared.replacements

        let messages =
            mode == .compact
            ? TranscriptPolishPromptBuilder.makeCompactMessages(
                rawText: raw,
                personalContext: personalContext,
                outputLanguage: outputLanguage,
                keyterms: keyterms,
                replacements: replacements
            )
            : TranscriptPolishPromptBuilder.makeMessages(
                rawText: raw,
                personalContext: personalContext,
                outputLanguage: outputLanguage,
                keyterms: keyterms,
                replacements: replacements
            )

        Task { @MainActor in
            do {
                let response = try await OpenAICompatiblePolisher().polish(
                    system: messages.system,
                    user: messages.user,
                    timeout: 12
                )
                let cleaned = PolishOutputSanitizer.clean(response.text, rawText: raw)
                state = .result(text: cleaned.isEmpty ? response.text : cleaned, mode: mode)
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }
}
