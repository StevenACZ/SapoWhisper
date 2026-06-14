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
    /// One raw token that must survive a literal polish. `.literal` anchors
    /// (numbers, URLs, emails, vocabulary) must appear verbatim — their
    /// punctuation is semantic (`5.5` != `55`). `.capitalizedWord` anchors
    /// (proper nouns / identifiers) also survive when only punctuation the
    /// polish legitimately fixes differs, so a dictation typo like `AGENTS..md`
    /// being corrected to `AGENTS.md` is not a false rejection — while dropping
    /// the `md` content (→ `AGENTS`) still fails.
    struct Anchor {
        enum Kind { case literal, capitalizedWord }
        let value: String
        let kind: Kind

        func survives(inLiteral literal: String, withoutPunctuation stripped: String) -> Bool {
            if literal.contains(value.lowercased()) { return true }
            guard kind == .capitalizedWord else { return false }
            let key = PolishFidelityGuard.strippingPunctuation(value).lowercased()
            guard key.count >= 3 else { return false }
            return stripped.contains(key)
        }
    }

    /// Polish removes fillers, so shrinking below 1.0 is normal.
    static let minimumLengthRatio = 0.55
    static let maximumLengthRatio = 1.6
    /// Dense scripts (CJK) compress a faithful translation to ~0.2–0.4 of the
    /// source character count, so the normal floor would reject them. This much
    /// lower floor still rejects extreme truncation/hallucination, while the
    /// unconditional ceiling keeps runaway-length protection.
    static let denseScriptMinimumLengthRatio = 0.15
    /// Fraction of letter/ideograph output that must be in a dense script
    /// before the lower floor applies.
    private static let denseScriptFractionThreshold = 0.35
    private static let maximumAnchors = 60

    /// Phrases that legitimately remove earlier content ("no espera, quise
    /// decir..."). Anchors spoken shortly before one are exempt because
    /// keeping only the corrected version is desired behavior.
    private static let selfCorrectionMarkers: [String] = [
        "no espera", "espera no", "quise decir", "quiero decir", "mejor dicho", "perdón", "perdon",
        "digo", "me equivoqué", "me equivoque", "no wait", "wait no", "i mean", "i meant",
        "scratch that", "correction", "sorry",
    ]

    /// `translationExpected` relaxes the language-bound anchors: a requested
    /// output language legitimately rewrites every regular word, so only
    /// translation-invariant tokens (numbers, URLs, emails, vocabulary) must
    /// survive.
    static func evaluate(
        raw: String,
        polished: String,
        vocabularyTerms: [String],
        translationExpected: Bool = false,
        targetIsDenseScript: Bool = false
    ) -> PolishFidelityVerdict {
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let polishedTrimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else {
            return PolishFidelityVerdict(isAcceptable: false, lengthRatio: 0, missingAnchors: 0, totalAnchors: 0)
        }

        let ratio = Double(polishedTrimmed.count) / Double(rawTrimmed.count)
        let anchors = extractAnchors(
            from: rawTrimmed,
            vocabularyTerms: vocabularyTerms,
            translationExpected: translationExpected
        )
        let polishedLowercased = polishedTrimmed.lowercased()
        let polishedWithoutPunctuation = strippingPunctuation(polishedTrimmed).lowercased()
        let missing = anchors.filter {
            !$0.survives(inLiteral: polishedLowercased, withoutPunctuation: polishedWithoutPunctuation)
        }

        // CJK targets compress a faithful translation well below the normal
        // floor, so lower the floor only when translating into a dense script
        // AND the output is actually dominantly dense (a half-translated mixed
        // output keeps the normal floor). The ceiling stays unconditional.
        let floor =
            (translationExpected && targetIsDenseScript
                && denseScriptFraction(of: polishedTrimmed) >= denseScriptFractionThreshold)
            ? denseScriptMinimumLengthRatio : minimumLengthRatio
        let ratioAcceptable = ratio >= floor && ratio <= maximumLengthRatio
        return PolishFidelityVerdict(
            isAcceptable: ratioAcceptable && missing.isEmpty,
            lengthRatio: ratio,
            missingAnchors: missing.count,
            totalAnchors: anchors.count
        )
    }

    /// Tokens that must survive a literal polish: numbers, URLs, emails,
    /// mid-sentence capitalized words, and vocabulary terms present in raw.
    /// Capitalized words are skipped when a translation is expected — they
    /// are regular words in the source language and legitimately change.
    static func extractAnchors(
        from raw: String,
        vocabularyTerms: [String],
        translationExpected: Bool = false
    ) -> [Anchor] {
        var anchors: [Anchor] = []
        var seen = Set<String>()

        func add(_ anchor: String, kind: Anchor.Kind) {
            let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key), anchors.count < maximumAnchors else { return }
            seen.insert(key)
            anchors.append(Anchor(value: trimmed, kind: kind))
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
                add(match, kind: .literal)
            }
        }

        if !translationExpected {
            for word in midSentenceCapitalizedWords(in: raw) where !isExempt(word) {
                add(word, kind: .capitalizedWord)
            }
        }

        let rawLowercased = raw.lowercased()
        for term in vocabularyTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, rawLowercased.contains(trimmed.lowercased()) else { continue }
            add(trimmed, kind: .literal)
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

    /// Removes Unicode punctuation while preserving whitespace, letters, and
    /// digits, so a capitalized-word anchor can be compared tolerantly to the
    /// punctuation a polish legitimately fixes (`AGENTS..md` vs `AGENTS.md`).
    static func strippingPunctuation(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Fraction of letter/ideograph scalars in `text` that belong to a dense
    /// (CJK) script. Whitespace, punctuation, digits, and symbols are excluded
    /// so embedded ASCII product names or numbers don't dilute the measure.
    private static func denseScriptFraction(of text: String) -> Double {
        var letterCount = 0
        var denseCount = 0
        for scalar in text.unicodeScalars {
            let dense = isDenseScriptScalar(scalar)
            guard dense || scalar.properties.isAlphabetic else { continue }
            letterCount += 1
            if dense { denseCount += 1 }
        }
        guard letterCount > 0 else { return 0 }
        return Double(denseCount) / Double(letterCount)
    }

    private static func isDenseScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,  // CJK Unified Ideographs
            0x3400...0x4DBF,  // CJK Extension A
            0xF900...0xFAFF,  // CJK Compatibility Ideographs
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0xAC00...0xD7AF:  // Hangul Syllables
            return true
        default:
            return false
        }
    }
}
