//
//  QuickHistoryPillView.swift
//  SapoWhisper
//

import SwiftUI

/// In-pill compact history opened from the dock chip: recent transcripts with
/// copy, prev/next paging and a current-engine re-transcribe — the fast path
/// that skips the full History window. Deliberately minimal: no pin, no AI
/// polish, no audio download, no duration.
struct QuickHistoryPillView: View {

    var onOpenHistory: ((Int64) -> Void)?
    var onRetranscribe: ((HistoryEntry) async -> String?)?
    var onClose: (() -> Void)?

    /// Same column as the completed pill so both browsing surfaces read as
    /// one component; the guardrail applies — multi-line Text needs this
    /// concrete width under the overlay's ideal-size layout.
    private static let contentWidth: CGFloat = 400
    private static let pageSize = 30

    @State private var entries: [HistoryEntry] = []
    @State private var index = 0
    @State private var hasLoaded = false
    @State private var reachedEnd = false
    @State private var isLoadingPage = false
    @State private var slideFromTrailing = true
    /// Keyed by row so paging mid-flight never pins one entry's failure
    /// under a different entry's footer.
    private struct RegenerateError: Equatable {
        let entryId: Int64
        let message: String
    }

    @State private var copiedFeedback = false
    @State private var regeneratingEntryId: Int64?
    @State private var regenerateError: RegenerateError?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var displayedEntry: HistoryEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    private var canGoOlder: Bool {
        index + 1 < entries.count || !reachedEnd
    }

    var body: some View {
        Group {
            if let entry = displayedEntry {
                browser(for: entry)
            } else if hasLoaded {
                emptyState
            } else {
                // One layout pass may run before the fetch lands; a small
                // stable placeholder keeps the droplet from popping empty.
                Color.clear.frame(width: 160, height: 22)
            }
        }
        .task { loadFirstPage() }
        .task(id: copiedFeedback) {
            guard copiedFeedback else { return }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Constants.Animation.reveal) { copiedFeedback = false }
        }
        .task(id: regenerateError) {
            guard regenerateError != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Constants.Animation.reveal) { regenerateError = nil }
        }
    }

    private func browser(for entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("overlay.quick_history_title".localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 16)

                OverlayIconButton(
                    systemName: "clock.arrow.circlepath",
                    label: "overlay.open_history".localized,
                    help: "overlay.open_history".localized,
                    action: { onOpenHistory?(entry.id) }
                )

                OverlayIconButton(
                    systemName: "xmark",
                    label: "overlay.close".localized,
                    help: "overlay.close".localized,
                    action: { onClose?() }
                )
            }

            ZStack {
                entryBody(for: entry)
                    .id(entry.id)
                    .transition(swapTransition)
            }

            footer(for: entry)
        }
        .frame(width: Self.contentWidth)
    }

    @ViewBuilder
    private func entryBody(for entry: HistoryEntry) -> some View {
        if entry.isUserCancelled {
            statusRow(
                icon: "xmark.circle.fill",
                text: "history.cancelled".localized,
                color: .secondary
            )
        } else if entry.isProcessing {
            statusRow(
                icon: "waveform.badge.magnifyingglass",
                text: (entry.entryStatus?.titleKey ?? "history.transcribing").localized,
                color: .secondary
            )
        } else if entry.status == "failed" {
            statusRow(
                icon: "exclamationmark.triangle.fill",
                text: "history.failed".localized,
                color: .sapoError
            )
        } else {
            Text(entry.text)
                .font(.system(size: 12))
                .lineSpacing(3.5)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .contentTransition(.opacity)
                .frame(width: Self.contentWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(color)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private func footer(for entry: HistoryEntry) -> some View {
        HStack(spacing: 8) {
            OverlayIconButton(
                systemName: "chevron.left",
                label: "overlay.quick_history_older".localized,
                help: "overlay.quick_history_older".localized,
                action: goOlder
            )
            .disabled(!canGoOlder)
            .opacity(canGoOlder ? 1 : 0.35)

            OverlayIconButton(
                systemName: "chevron.right",
                label: "overlay.quick_history_newer".localized,
                help: "overlay.quick_history_newer".localized,
                action: goNewer
            )
            .disabled(index == 0)
            .opacity(index == 0 ? 0.35 : 1)

            if let regenerateError, regenerateError.entryId == entry.id {
                Text(regenerateError.message)
                    .font(.system(size: 10))
                    .foregroundColor(.sapoError)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            } else {
                Text(entry.compactRelativeTime)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            if regeneratingEntryId == entry.id {
                TranscribingIndicator(color: .sapoGreenText)
            } else if entry.audioFileExists {
                OverlayIconButton(
                    systemName: "arrow.clockwise",
                    label: "overlay.quick_history_regenerate".localized,
                    help: "overlay.quick_history_regenerate".localized,
                    action: { regenerate(entry) }
                )
                .disabled(regeneratingEntryId != nil)
            }

            if !entry.text.isEmpty {
                OverlayIconButton(
                    systemName: copiedFeedback ? "checkmark" : "doc.on.doc",
                    label: "overlay.copy".localized,
                    help: "overlay.copy".localized,
                    action: { copy(entry) }
                )
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            Text("overlay.quick_history_empty".localized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            OverlayIconButton(
                systemName: "xmark",
                label: "overlay.close".localized,
                help: "overlay.close".localized,
                action: { onClose?() }
            )
        }
        .frame(minWidth: 230)
    }

    /// Entries hand off like carousel pages: older slides in from the
    /// trailing edge, newer from the leading one.
    private var swapTransition: AnyTransition {
        reduceMotion ? .opacity : .push(from: slideFromTrailing ? .trailing : .leading)
    }

    // MARK: - Navigation

    private func goOlder() {
        slideFromTrailing = true
        if index + 1 < entries.count {
            advance(to: index + 1)
            prefetchIfNearEnd()
        } else if !reachedEnd {
            Task {
                loadNextPage()
                if index + 1 < entries.count {
                    advance(to: index + 1)
                }
            }
        }
    }

    private func goNewer() {
        guard index > 0 else { return }
        slideFromTrailing = false
        advance(to: index - 1)
    }

    private func advance(to newIndex: Int) {
        withAnimation(reduceMotion ? nil : Constants.Animation.morph) {
            index = newIndex
            copiedFeedback = false
        }
    }

    // MARK: - Data

    private func loadFirstPage() {
        guard !hasLoaded else { return }
        entries = TranscriptionHistoryManager.shared.fetchEntries(limit: Self.pageSize)
        reachedEnd = entries.count < Self.pageSize
        hasLoaded = true
    }

    private func loadNextPage() {
        guard !isLoadingPage, !reachedEnd else { return }
        isLoadingPage = true
        let page = TranscriptionHistoryManager.shared.fetchEntries(
            limit: Self.pageSize, offset: entries.count)
        // A dictation finishing mid-browse shifts the offset; dedup by id so
        // the carousel never shows the same take twice.
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: page.filter { !known.contains($0.id) })
        reachedEnd = page.count < Self.pageSize
        isLoadingPage = false
    }

    private func prefetchIfNearEnd() {
        guard index >= entries.count - 3, !reachedEnd, !isLoadingPage else { return }
        loadNextPage()
    }

    // MARK: - Actions

    private func copy(_ entry: HistoryEntry) {
        PasteManager.copyToClipboard(entry.text)
        withAnimation(Constants.Animation.microBounce) { copiedFeedback = true }
    }

    private func regenerate(_ entry: HistoryEntry) {
        guard regeneratingEntryId == nil, let onRetranscribe else { return }
        withAnimation(Constants.Animation.reveal) {
            regenerateError = nil
            regeneratingEntryId = entry.id
        }
        Task {
            let errorMessage = await onRetranscribe(entry)
            let refreshed = TranscriptionHistoryManager.shared.entry(id: entry.id)
            withAnimation(reduceMotion ? nil : Constants.Animation.morph) {
                if let refreshed, let position = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[position] = refreshed
                }
                regenerateError = errorMessage.map {
                    RegenerateError(entryId: entry.id, message: $0)
                }
                regeneratingEntryId = nil
            }
        }
    }
}
