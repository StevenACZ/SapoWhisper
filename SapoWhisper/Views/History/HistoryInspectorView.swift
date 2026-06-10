//
//  HistoryInspectorView.swift
//  SapoWhisper

import SwiftUI

/// Inspector panel showing metadata and actions for a selected history entry
struct HistoryInspectorView: View {
    let entry: HistoryEntry
    let onCopy: () -> Void
    let onRetranscribe: () -> Void
    let onPolishWithAI: () -> Void
    let onDownloadAudio: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    var isAIPolishing = false

    @State private var showCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailsSection
                Divider()
                actionsSection
            }
            .padding(16)
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "history.details".localized)

            VStack(alignment: .leading, spacing: 10) {
                MetadataRow(icon: "cpu", label: "history.engine".localized, value: entry.displayEngineName)
                MetadataRow(icon: "globe", label: "history.language".localized, value: entry.language.uppercased())
                MetadataRow(icon: "clock", label: "history.duration".localized, value: entry.formattedDuration)
                MetadataRow(icon: "text.word.spacing", label: "history.words".localized, value: "\(entry.wordCount)")
                MetadataRow(
                    icon: "waveform",
                    label: "history.audio".localized,
                    value: entry.audioFileExists ? "history.audio_saved".localized : "history.audio_none".localized,
                    valueColor: entry.audioFileExists ? Color.sapoGreen : .secondary
                )
                MetadataRow(
                    icon: entry.status == "completed" ? "checkmark.circle" : "xmark.circle",
                    label: "history.status".localized,
                    value: statusText,
                    valueColor: entry.status == "completed" ? Color.sapoGreen : .orange
                )
                MetadataRow(
                    icon: "wand.and.stars",
                    label: "history.ai_polish".localized,
                    value: aiStatusText,
                    valueColor: aiStatusColor
                )
                if let firstPolishText {
                    MetadataRow(
                        icon: "clock.arrow.circlepath",
                        label: "history.ai_first_polish".localized,
                        value: firstPolishText,
                        valueColor: .secondary
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "history.actions".localized)

            InspectorButton(
                label: showCopied ? "history.copied".localized : "history.copy".localized,
                icon: showCopied ? "checkmark" : "doc.on.doc",
                action: handleCopy
            )

            if entry.audioFileExists {
                InspectorButton(
                    label: "history.retranscribe_with".localized,
                    icon: "arrow.clockwise",
                    action: onRetranscribe
                )

                InspectorButton(
                    label: "history.download_audio".localized,
                    icon: "square.and.arrow.down",
                    action: onDownloadAudio
                )
            }

            if entry.status == "completed", !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                InspectorButton(
                    label: isAIPolishing ? "history.ai_polishing".localized : "history.ai_polish_action".localized,
                    icon: "wand.and.stars",
                    isDisabled: isAIPolishing,
                    action: onPolishWithAI
                )
            }

            InspectorButton(
                label: entry.isFavorite ? "history.unpin".localized : "history.pin".localized,
                icon: entry.isFavorite ? "pin.slash" : "pin",
                action: onTogglePin
            )

            Divider()
                .padding(.vertical, 4)

            InspectorButton(
                label: "history.delete".localized,
                icon: "trash",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    private func handleCopy() {
        onCopy()
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    /// H7: failed rows show the semantic failure code next to the status.
    private var statusText: String {
        if entry.status == "completed" {
            return "history.status_completed".localized
        }
        var text = "history.status_failed".localized
        if let failureCode = entry.failureCode, !failureCode.isEmpty {
            text += " · \(failureCode)"
        }
        return text
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

    private var aiStatusText: String {
        var parts = [entry.transcriptAIStatus.displayName]
        if let modeName = entry.aiModeDisplayName {
            parts.append(modeName)
        }
        if let model = entry.aiModel, !model.isEmpty {
            parts.append(model)
        }
        if let error = entry.aiError, !error.isEmpty {
            parts.append(error)
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
}

// MARK: - Subcomponents

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct MetadataRow: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(valueColor)
            }
        }
    }
}

private struct InspectorButton: View {
    let label: String
    let icon: String
    var isDestructive: Bool = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(label)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(isDestructive ? .red : .primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .background(.quaternary.opacity(0.01))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Preview

#Preview("Inspector") {
    HistoryInspectorView(
        entry: HistoryEntry.mockData[0],
        onCopy: {},
        onRetranscribe: {},
        onPolishWithAI: {},
        onDownloadAudio: {},
        onTogglePin: {},
        onDelete: {}
    )
    .frame(width: 220, height: 500)
}
