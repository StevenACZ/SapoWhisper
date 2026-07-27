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
    /// nil polishes with the globally configured provider; an option polishes
    /// with that explicit endpoint/model (menu selection).
    let onPolishWithAI: (PolishModelOption?) -> Void
    let onRetranscribe: () -> Void
    let onDownloadAudio: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var showCopied = false
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var polishVersions: [PolishVersion] = []
    @Environment(\.locale) private var locale
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false

    private var isFailed: Bool { entry.status == "failed" }
    private var isUserCancelled: Bool { entry.isUserCancelled }
    /// Pre-persisted row whose engine is still running (live only — stale
    /// ones resolve to failed at launch).
    private var isTranscribing: Bool { !entry.isDeletable }

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
                } else if isTranscribing {
                    transcribingCard
                } else if isFailed {
                    failedCard
                } else {
                    transcriptSection
                    originalTextSection
                    polishVersionsSection
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
        // Keyed on the whole entry (not just the id): a re-polish rewrites the
        // row in place, and the trail must refresh with it.
        .task(id: entry) {
            polishVersions = TranscriptionHistoryManager.shared.polishVersions(for: entry.id)
        }
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
                HeaderChip(text: entry.engine, dotColor: HistoryEngineColor.color(for: entry.engine))
                HeaderChip(text: entry.language.uppercased())
            }
        }
    }

    /// Cached: building a DateFormatter per body evaluation is expensive.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// "Today at 3:42 PM" — relative day names read faster than raw dates.
    private var formattedTimestamp: String {
        let formatter = Self.timestampFormatter
        // Environment locale can change at runtime (app language switch).
        if formatter.locale != locale {
            formatter.locale = locale
        }
        return formatter.string(from: entry.timestamp)
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: handleCopy) {
                Label {
                    Text(showCopied ? "history.copied".localized : "history.copy".localized)
                } icon: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.sapoGreenDark)
            .fixedSize()
            .disabled(isFailed || entry.text.isEmpty)

            if canPolish {
                polishMenu
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
            .disabled(!entry.isDeletable)
        }
        .controlSize(.regular)
    }

    /// Every polish target the user has configured: current model plus the
    /// recents of each endpoint with a usable setup. The list is rebuilt on
    /// each body pass from UserDefaults hints only (no keychain reads).
    private var polishModelOptions: [PolishModelOption] {
        PolishProviderConfiguration.availableModelOptions()
    }

    /// "Improve with AI" opens the model picker; re-polishing always starts
    /// from the raw transcript, so trying several models is non-destructive.
    @ViewBuilder
    private var polishMenu: some View {
        let options = polishModelOptions
        if options.isEmpty {
            // Nothing configured beyond the global provider: keep the plain
            // one-click button.
            Button {
                onPolishWithAI(nil)
            } label: {
                polishMenuLabel
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(isAIPolishing || !aiPolishEnabled)
            .help(aiPolishEnabled ? "" : "history.ai_polish_disabled_hint".localized)
        } else {
            Menu {
                Section("history.ai_polish_choose_model".localized) {
                    ForEach(options) { option in
                        Button(option.displayName) {
                            onPolishWithAI(option)
                        }
                    }
                }
            } label: {
                polishMenuLabel
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .fixedSize()
            .disabled(isAIPolishing || !aiPolishEnabled)
            .help(aiPolishEnabled ? "" : "history.ai_polish_disabled_hint".localized)
        }
    }

    private var polishMenuLabel: some View {
        Label(
            isAIPolishing
                ? "history.ai_polishing".localized
                : "history.ai_polish_action".localized,
            systemImage: "wand.and.stars"
        )
    }

    private func handleCopy() {
        onCopy()
        withAnimation(Constants.Animation.transition) {
            showCopied = true
        }
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(Constants.Animation.transition) {
                showCopied = false
            }
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
                valueColor: entry.audioFileExists ? Color.sapoGreenText : .secondary
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
            return .sapoGreenText
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

    /// Full regeneration trail, newest first. Shown once the entry has at
    /// least one applied polish; the newest version is what the transcript
    /// above already shows, so it is tagged as current instead of repeated
    /// silently.
    @ViewBuilder
    private var polishVersionsSection: some View {
        if !polishVersions.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(polishVersions.enumerated()), id: \.element.id) { index, version in
                        PolishVersionRow(
                            version: version,
                            number: polishVersions.count - index,
                            isCurrent: index == 0
                        )
                        if index < polishVersions.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(
                    "history.polish_versions".localized(polishVersions.count),
                    systemImage: "clock.arrow.circlepath"
                )
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
                .tint(Constants.Colors.warningProminent)
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

    private var transcribingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text("history.transcribing".localized)
                .font(.title3.weight(.semibold))

            Text("history.transcribing_detail".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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
                .tint(Color.sapoGreenDark)
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
}

// MARK: - Subcomponents

/// One applied polish in the entry's regeneration trail: version number,
/// model, time, and the full text (selectable + one-click copy).
private struct PolishVersionRow: View {
    let version: PolishVersion
    let number: Int
    let isCurrent: Bool

    @State private var showCopied = false
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("v\(number)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.sapoGreenText : Color.secondary)

                if let model = version.model, !model.isEmpty {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(formattedTime)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if isCurrent {
                    Text("history.polish_version_current".localized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.sapoGreen.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.sapoGreenText)
                }

                Spacer(minLength: 8)

                Button {
                    PasteManager.copyToClipboard(version.text)
                    showCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopied = false
                    }
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("history.copy".localized)
                .accessibilityLabel("history.copy".localized)
            }

            Text(version.text)
                .font(.callout)
                .lineSpacing(5)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private var formattedTime: String {
        let formatter = Self.timeFormatter
        if formatter.locale != locale {
            formatter.locale = locale
        }
        return formatter.string(from: version.createdAt)
    }
}

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
        .accessibilityLabel(help)
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
        onPolishWithAI: { _ in },
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
        onPolishWithAI: { _ in },
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
