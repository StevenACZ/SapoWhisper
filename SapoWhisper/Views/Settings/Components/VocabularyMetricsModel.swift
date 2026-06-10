//
//  VocabularyMetricsModel.swift
//  SapoWhisper
//

import Combine
import Foundation

/// Computes vocabulary usage metrics off the main actor and caches the
/// scanned transcripts so vocabulary edits only re-count, never re-query.
@MainActor
final class VocabularyMetricsModel: ObservableObject {
    @Published private(set) var metrics = VocabularyUsageMetrics.empty
    /// Appearance count per normalized (lowercased) term, for chip badges.
    @Published private(set) var termCounts: [String: Int] = [:]

    /// Recent-history window the metrics are based on.
    nonisolated static let historyFetchLimit = 200
    private nonisolated static let refreshDebounce: Duration = .seconds(1)

    private var cachedTranscripts: [String]?
    private var cachedWordsPerMinute: Int?
    private var generation = 0
    private var debounceTask: Task<Void, Never>?

    /// Full refresh: queries recent history and recomputes everything.
    func refreshFromHistory(keyterms: [String], replacementValues: [String]) {
        generation += 1
        let expected = generation

        Task.detached(priority: .utility) {
            // TranscriptionHistoryManager is thread-safe (FULLMUTEX SQLite),
            // so the query and the counting both stay off the main actor.
            let entries = TranscriptionHistoryManager.shared.fetchEntries(limit: Self.historyFetchLimit)
            let transcripts = VocabularyUsageCalculator.countableTranscripts(from: entries)
            let wordsPerMinute = VocabularyUsageCalculator.averageWordsPerMinute(entries: entries)
            let result = Self.count(
                keyterms: keyterms,
                replacementValues: replacementValues,
                transcripts: transcripts,
                wordsPerMinute: wordsPerMinute
            )

            await self.apply(
                result,
                transcripts: transcripts,
                wordsPerMinute: wordsPerMinute,
                ifGeneration: expected
            )
        }
    }

    /// Debounced refresh for history-change notifications, which arrive in
    /// bursts while a dictation is being persisted or re-polished.
    func scheduleRefreshFromHistory(keyterms: [String], replacementValues: [String]) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled else { return }
            self?.refreshFromHistory(keyterms: keyterms, replacementValues: replacementValues)
        }
    }

    /// Re-counts on the cached transcripts after a vocabulary edit — no
    /// SQLite round trip. Falls back to a full refresh on first use.
    func recountTerms(keyterms: [String], replacementValues: [String]) {
        guard let transcripts = cachedTranscripts else {
            refreshFromHistory(keyterms: keyterms, replacementValues: replacementValues)
            return
        }

        generation += 1
        let expected = generation
        let wordsPerMinute = cachedWordsPerMinute

        Task.detached(priority: .utility) {
            let result = Self.count(
                keyterms: keyterms,
                replacementValues: replacementValues,
                transcripts: transcripts,
                wordsPerMinute: wordsPerMinute
            )
            await self.apply(
                result,
                transcripts: transcripts,
                wordsPerMinute: wordsPerMinute,
                ifGeneration: expected
            )
        }
    }

    private nonisolated static func count(
        keyterms: [String],
        replacementValues: [String],
        transcripts: [String],
        wordsPerMinute: Int?
    ) -> (metrics: VocabularyUsageMetrics, termCounts: [String: Int]) {
        let topTerms = VocabularyUsageCalculator.topTerms(
            keyterms: keyterms,
            replacementValues: replacementValues,
            inLowercasedTranscripts: transcripts
        )
        let counts = VocabularyUsageCalculator.termCounts(
            terms: keyterms + replacementValues,
            inLowercasedTranscripts: transcripts
        )
        let metrics = VocabularyUsageMetrics(averageWordsPerMinute: wordsPerMinute, topTerms: topTerms)
        return (metrics, counts)
    }

    private func apply(
        _ result: (metrics: VocabularyUsageMetrics, termCounts: [String: Int]),
        transcripts: [String],
        wordsPerMinute: Int?,
        ifGeneration expected: Int
    ) {
        guard expected == generation else { return }
        cachedTranscripts = transcripts
        cachedWordsPerMinute = wordsPerMinute
        metrics = result.metrics
        termCounts = result.termCounts
    }
}
