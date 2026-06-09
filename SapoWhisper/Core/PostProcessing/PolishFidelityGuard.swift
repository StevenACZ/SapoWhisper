//
//  PolishFidelityGuard.swift
//  SapoWhisper
//

import Foundation

struct PolishFidelityVerdict {
    let isAcceptable: Bool
    let lengthRatio: Double
    let missingAnchors: Int
    let totalAnchors: Int

    /// Counts only — never transcript content.
    var diagnosticSummary: String {
        String(format: "ratio=%.2f missingAnchors=%d/%d", lengthRatio, missingAnchors, totalAnchors)
    }
}

/// Hard post-response bound on how far polished text may drift from the raw
/// transcript. On violation the caller pastes the raw transcript instead —
/// this is what eliminates the catastrophic "said something else" case for
/// every provider.
enum PolishFidelityGuard {
    /// Polish removes fillers, so shrinking below 1.0 is normal.
    static let minimumLengthRatio = 0.55
    static let maximumLengthRatio = 1.6
    private static let maximumAnchors = 60

    /// Phrases that legitimately remove earlier content ("no espera, quise
    /// decir..."). Anchors spoken shortly before one are exempt because
    /// keeping only the corrected version is desired behavior.
    private static let selfCorrectionMarkers: [String] = [
        "no espera", "espera no", "quise decir", "quiero decir", "mejor dicho", "perdón", "perdon",
        "digo", "me equivoqué", "me equivoque", "no wait", "wait no", "i mean", "i meant",
        "scratch that", "correction", "sorry",
    ]

    static func evaluate(raw: String, polished: String, vocabularyTerms: [String]) -> PolishFidelityVerdict {
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let polishedTrimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else {
            return PolishFidelityVerdict(isAcceptable: false, lengthRatio: 0, missingAnchors: 0, totalAnchors: 0)
        }

        let ratio = Double(polishedTrimmed.count) / Double(rawTrimmed.count)
        let anchors = extractAnchors(from: rawTrimmed, vocabularyTerms: vocabularyTerms)
        let polishedLowercased = polishedTrimmed.lowercased()
        let missing = anchors.filter { !polishedLowercased.contains($0.lowercased()) }

        let ratioAcceptable = ratio >= minimumLengthRatio && ratio <= maximumLengthRatio
        return PolishFidelityVerdict(
            isAcceptable: ratioAcceptable && missing.isEmpty,
            lengthRatio: ratio,
            missingAnchors: missing.count,
            totalAnchors: anchors.count
        )
    }

    /// Tokens that must survive a literal polish: numbers, URLs, emails,
    /// mid-sentence capitalized words, and vocabulary terms present in raw.
    static func extractAnchors(from raw: String, vocabularyTerms: [String]) -> [String] {
        var anchors: [String] = []
        var seen = Set<String>()

        func add(_ anchor: String) {
            let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key), anchors.count < maximumAnchors else { return }
            seen.insert(key)
            anchors.append(trimmed)
        }

        let exemptSegments = selfCorrectionExemptSegments(in: raw)
        func isExempt(_ candidate: String) -> Bool {
            let lowered = candidate.lowercased()
            return exemptSegments.contains { $0.contains(lowered) }
        }

        for pattern in [
            #"[0-9]+(?:[.,:][0-9]+)*"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"https?://[^\s]+"#,
            #"\bwww\.[^\s]+"#,
        ] {
            for match in matches(of: pattern, in: raw) where !isExempt(match) {
                add(match)
            }
        }

        for word in midSentenceCapitalizedWords(in: raw) where !isExempt(word) {
            add(word)
        }

        let rawLowercased = raw.lowercased()
        for term in vocabularyTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, rawLowercased.contains(trimmed.lowercased()) else { continue }
            add(trimmed)
        }

        return anchors
    }

    private static func midSentenceCapitalizedWords(in raw: String) -> [String] {
        var results: [String] = []
        let sentenceEnders: Set<Character> = [".", "!", "?", ":", ";", "…"]

        for line in raw.components(separatedBy: .newlines) {
            var previousToken: Substring?
            for token in line.split(separator: " ") {
                defer { previousToken = token }
                guard let previous = previousToken, let previousLast = previous.last else { continue }
                guard !sentenceEnders.contains(previousLast) else { continue }

                let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
                guard cleaned.count >= 3, let first = cleaned.first, first.isUppercase, first.isLetter else { continue }
                results.append(cleaned)
            }
        }
        return results
    }

    /// Lowercased raw substrings spanning the ~40 characters before each
    /// self-correction marker (plus the marker itself).
    private static func selfCorrectionExemptSegments(in raw: String) -> [String] {
        let lowercased = raw.lowercased()
        var segments: [String] = []
        for marker in selfCorrectionMarkers {
            var searchStart = lowercased.startIndex
            while let found = lowercased.range(of: marker, range: searchStart..<lowercased.endIndex) {
                let windowStart =
                    lowercased.index(found.lowerBound, offsetBy: -40, limitedBy: lowercased.startIndex)
                    ?? lowercased.startIndex
                segments.append(String(lowercased[windowStart..<found.upperBound]))
                searchStart = found.upperBound
            }
        }
        return segments
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
