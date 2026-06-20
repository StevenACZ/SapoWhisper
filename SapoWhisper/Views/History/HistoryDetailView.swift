//
//  HistoryDetailView.swift
//  SapoWhisper

import SwiftUI

/// Reading pane for one history entry: date header, action bar, stats strip,
/// transcript, optional original text, and the audio player. Replaces the old
/// cramped third-column inspector — everything lives in one wide pane.
struct HistoryDetailView: View {
    let entry: HistoryEntry
    var isAIPolishing = false
    let onCopy: () -> Void
    let onPolishWithAI: () -> Void
    let onRetranscribe: () -> Void
    let onDownloadAudio: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var showCopied = false
    @Environment(\.locale) private var locale
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false

    private var isFailed: Bool { entry.status == "failed" }
    private var isUserCancelled: Bool { entry.isUserCancelled }

    private var canPolish: Bool {
        entry.status == "completed"
            && !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actionBar

                VStack(alignment: .leading, spacing: 10) {
                    statsStrip
                    polishDetailLines
                }

                if isUserCancelled {
                    cancelledCard
                } else if isFailed {
                    failedCard
                } else {
                    transcriptSection
                    originalTextSection
                }

                if entry.audioFileExists, let path = entry.audioPath {
                    AudioPlayerView(audioPath: path)
                        .id(path)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(formattedTimestamp)
                    .font(.title2.weight(.semibold))

                if entry.isFavorite {
                    Image(systemName: "pin.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                HeaderChip(text: entry.engine, dotColor: engineColor)
                HeaderChip(text: entry.language.uppercased())
            }
        }
    }

    /// "Today at 3:42 PM" — relative day names read faster than raw dates.
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: entry.timestamp)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: handleCopy) {
                Label(
                    showCopied ? "history.copied".localized : "history.copy".localized,
                    systemImage: showCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.sapoGreen)
            .fixedSize()
            .disabled(isFailed || entry.text.isEmpty)

            if canPolish {
                Button(action: onPolishWithAI) {
                    Label(
                        isAIPolishing
                            ? "history.ai_polishing".localized
                            : "history.ai_polish_action".localized,
                        systemImage: "wand.and.stars"
                    )
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(isAIPolishing || !aiPolishEnabled)
                .help(aiPolishEnabled ? "" : "history.ai_polish_disabled_hint".localized)
            }

            Spacer(minLength: 12)

            if entry.audioFileExists {
                IconActionButton(
                    systemImage: "arrow.clockwise",
                    help: "history.retranscribe_with".localized,
                    action: onRetranscribe
                )

                IconActionButton(
                    systemImage: "square.and.arrow.down",
                    help: "history.download_audio".localized,
                    action: onDownloadAudio
                )
            }

            IconActionButton(
                systemImage: entry.isFavorite ? "pin.slash" : "pin",
                help: (entry.isFavorite ? "history.unpin" : "history.pin").localized,
                action: onTogglePin
            )

            IconActionButton(
                systemImage: "trash",
                help: "history.delete".localized,
                role: .destructive,
                action: onDelete
            )
        }
        .controlSize(.regular)
    }

    private func handleCopy() {
        onCopy()
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    // MARK: - Stats

    private var statsStrip: some View {
        HStack(spacing: 0) {
            StatCell(value: entry.formattedDuration, label: "history.duration".localized)
            StatDivider()
            StatCell(value: "\(entry.wordCount)", label: "history.words".localized)
            StatDivider()
            StatCell(value: entry.language.uppercased(), label: "history.language".localized)
            StatDivider()
            StatCell(
                value: entry.transcriptAIStatus.displayName,
                label: "history.ai_polish".localized,
                valueColor: aiStatusColor
            )
            StatDivider()
            StatCell(
                value: (entry.audioFileExists ? "history.audio_saved" : "history.audio_none").localized,
                label: "history.audio".localized,
                valueColor: entry.audioFileExists ? Color.sapoGreen : .secondary
            )
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
    }

    /// Model/mode/error context that used to live in the inspector; shown
    /// only when there is something beyond the bare status.
    @ViewBuilder
    private var polishDetailLines: some View {
        if let detail = polishDetailText {
            Label(detail, systemImage: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(entry.aiError == nil ? Color.secondary : Color.orange)
        }

        if let firstPolishText {
            Label("\("history.ai_first_polish".localized): \(firstPolishText)", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var polishDetailText: String? {
        var parts: [String] = []
        if let modeName = entry.aiModeDisplayName {
            parts.append(modeName)
        }
        if let model = entry.aiModel, !model.isEmpty {
            parts.append(model)
        }
        if let error = entry.aiError, !error.isEmpty {
            parts.append(error)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// H10: first applied polish, shown when a re-polish replaced it.
    private var firstPolishText: String? {
        guard let firstStatus = entry.aiFirstStatus, !firstStatus.isEmpty else { return nil }
        var parts = [TranscriptAIStatus(rawValue: firstStatus)?.displayName ?? firstStatus]
        if let mode = entry.aiFirstMode, !mode.isEmpty {
            parts.append(mode)
        }
        if let model = entry.aiFirstModel, !model.isEmpty {
            parts.append(model)
        }
        return parts.joined(separator: " · ")
    }

    private var aiStatusColor: Color {
        switch entry.transcriptAIStatus {
        case .applied:
            return .sapoGreen
        case .failed, .rejectedFidelity:
            return .orange
        case .skippedShort, .skippedDuration, .none:
            return .secondary
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        Text(entry.text)
            .font(.system(size: 17))
            .lineSpacing(7)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var originalTextSection: some View {
        if entry.hasRawTranscript {
            DisclosureGroup {
                Text(entry.rawText)
                    .font(.callout)
                    .lineSpacing(5)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            } label: {
                Label("history.original_text".localized, systemImage: "text.alignleft")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Failed

    private var failedCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("history.failed".localized)
                .font(.title3.weight(.semibold))

            if let failureCode = entry.failureCode, !failureCode.isEmpty {
                Text(failureCode)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.14), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Text("history.failed_detail".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if entry.audioFileExists {
                Button(action: onRetranscribe) {
                    Label("history.retranscribe_with".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.orange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var cancelledCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("history.cancelled".localized)
                .font(.title3.weight(.semibold))

            Text("history.cancelled_detail".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if entry.audioFileExists {
                Button(action: onRetranscribe) {
                    Label("history.retranscribe_with".localized, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.sapoGreen)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var engineColor: Color {
        switch entry.engine.lowercased() {
        case let e where e.contains("local ai"): return .indigo
        case let e where e.contains("elevenlabs"): return .teal
        case let e where e.contains("deepgram"): return .blue
        case let e where e.contains("gemini"): return .cyan
        case let e where e.contains("google"): return .orange
        case let e where e.contains("whisper"): return .purple
        case let e where e.contains("apple"): return .green
        default: return .secondary
        }
    }
}

// MARK: - Subcomponents

private struct HeaderChip: View {
    let text: String
    var dotColor: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

private struct StatCell: View {
    let value: String
    let label: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }
}

private struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 26)
    }
}

private struct IconActionButton: View {
    let systemImage: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

// MARK: - Empty State

struct HistoryEmptyDetailView: View {
    var hasEntries = false

    var body: some View {
        if hasEntries {
            ContentUnavailableView(
                "history.select_transcription".localized,
                systemImage: "text.quote",
                description: Text("history.select_transcription_sub".localized)
            )
        } else {
            ContentUnavailableView(
                "history.empty".localized,
                systemImage: "clock.arrow.circlepath",
                description: Text("history.empty_sub".localized)
            )
        }
    }
}

// MARK: - Previews

#Preview("Detail - Text") {
    HistoryDetailView(
        entry: HistoryEntry.mockData[0],
        onCopy: {},
        onPolishWithAI: {},
        onRetranscribe: {},
        onDownloadAudio: {},
        onTogglePin: {},
        onDelete: {}
    )
    .frame(width: 660, height: 540)
}

#Preview("Detail - Failed") {
    HistoryDetailView(
        entry: HistoryEntry.mockData[3],
        onCopy: {},
        onPolishWithAI: {},
        onRetranscribe: {},
        onDownloadAudio: {},
        onTogglePin: {},
        onDelete: {}
    )
    .frame(width: 660, height: 540)
}

#Preview("Detail - Empty") {
    HistoryEmptyDetailView(hasEntries: true)
        .frame(width: 660, height: 540)
}
