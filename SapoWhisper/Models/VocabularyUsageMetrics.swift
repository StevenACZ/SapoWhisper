//
//  VocabularyUsageMetrics.swift
//  SapoWhisper
//

import Foundation

/// Usage metrics surfaced at the top of the Vocabulary tab, computed from
/// recent history entries — no extra tracking is persisted anywhere.
nonisolated struct VocabularyUsageMetrics: Sendable, Equatable {
    struct TermUsage: Sendable, Equatable, Identifiable {
        let term: String
        let count: Int

        var id: String { term }
    }

    /// Average dictation pace; nil when there is not enough history.
    var averageWordsPerMinute: Int?
    /// Vocabulary terms (keyterms and replacement values) that appear most in
    /// recent transcripts, highest count first.
    var topTerms: [TermUsage]

    static let empty = VocabularyUsageMetrics(averageWordsPerMinute: nil, topTerms: [])
}

/// Pure counting helpers for `VocabularyUsageMetrics`. Kept free of UI and
/// managers so they are trivially testable and safe to run off the main actor.
nonisolated enum VocabularyUsageCalculator {
    /// Per-transcript cap so a pathological row cannot stall the counter.
    static let transcriptCharacterCap = 50_000
    /// Recordings shorter than this skew words-per-minute wildly; skip them.
    static let minimumPaceDuration: TimeInterval = 5
    static let topTermLimit = 3

    /// Lowercased, capped transcript texts ready for term counting.
    static func countableTranscripts(from entries: [HistoryEntry]) -> [String] {
        entries
            .filter { $0.status == "completed" && !$0.text.isEmpty }
            .map { String($0.text.prefix(transcriptCharacterCap)).lowercased() }
    }

    static func averageWordsPerMinute(entries: [HistoryEntry]) -> Int? {
        let usable = entries.filter {
            $0.status == "completed" && $0.duration > minimumPaceDuration && $0.wordCount > 0
        }
        let totalWords = usable.reduce(0) { $0 + $1.wordCount }
        let totalMinutes = usable.reduce(0.0) { $0 + $1.duration } / 60
        guard totalMinutes > 0 else { return nil }
        return Int((Double(totalWords) / totalMinutes).rounded())
    }

    /// Top vocabulary terms by appearances in the given lowercased transcripts.
    /// Replacement *values* are counted as a proxy for how often a correction
    /// fires — applications are not persisted, only the corrected output is.
    static func topTerms(
        keyterms: [String],
        replacementValues: [String],
        inLowercasedTranscripts transcripts: [String]
    ) -> [VocabularyUsageMetrics.TermUsage] {
        var seen = Set<String>()
        var usages: [VocabularyUsageMetrics.TermUsage] = []

        for term in keyterms + replacementValues {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let count = transcripts.reduce(0) { $0 + occurrences(of: normalized, inLowercased: $1) }
            if count > 0 {
                usages.append(VocabularyUsageMetrics.TermUsage(term: trimmed, count: count))
            }
        }

        return Array(usages.sorted { $0.count > $1.count }.prefix(topTermLimit))
    }

    /// Counts per-term appearances for badge display, keyed by the normalized
    /// (lowercased) term.
    static func termCounts(
        terms: [String],
        inLowercasedTranscripts transcripts: [String]
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        for term in terms {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, counts[normalized] == nil else { continue }
            let count = transcripts.reduce(0) { $0 + occurrences(of: normalized, inLowercased: $1) }
            if count > 0 {
                counts[normalized] = count
            }
        }
        return counts
    }

    /// Whole-word occurrences of `needle` (already lowercased) in `text`
    /// (already lowercased). Word boundary = neighbors are not alphanumeric,
    /// so short terms ("pr") don't match inside words ("print").
    static func occurrences(of needle: String, inLowercased text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            if hasWordBoundary(around: range, in: text) {
                count += 1
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func hasWordBoundary(around range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }
}
