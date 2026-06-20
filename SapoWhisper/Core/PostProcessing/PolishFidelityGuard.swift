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

/// Minimal post-response bound on how far polished text may drift from the raw
/// transcript. This is intentionally deterministic and narrow: it protects
/// tokens that should not silently change, while leaving regular wording,
/// cleanup, and translation decisions to the AI prompt.
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
            let needle = value.lowercased()
            // Numeric anchors match whole numeric tokens, never substrings: "5"
            // must not survive inside "15", "5.5", "5,000" or "5:30". Numeric
            // punctuation is semantic (5.5 != 55), so a changed number fails.
            if kind == .literal, PolishFidelityGuard.isNumericLiteral(value) {
                return PolishFidelityGuard.orderedNumericTokens(in: literal).contains(needle)
            }
            if literal.contains(needle) { return true }
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

    private static let numericPattern = #"[0-9]+(?:[.,:][0-9]+)*"#
    private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let urlPattern = #"https?://[^\s]+"#
    private static let wwwPattern = #"\bwww\.[^\s]+"#

    /// Phrases that legitimately remove earlier content ("no espera, quise
    /// decir..."). Anchors spoken shortly before one are exempt because
    /// keeping only the corrected version is desired behavior.
    private static let selfCorrectionMarkers: [String] = [
        "no espera", "espera no", "quise decir", "quiero decir", "mejor dicho", "perdón", "perdon",
        "digo", "me equivoqué", "me equivoque", "no wait", "wait no", "i mean", "i meant",
        "scratch that", "correction", "sorry",
    ]
    private static let capitalizedWordStopAnchors: Set<String> = [
        "bueno", "dale", "listo", "obviamente", "perfecto",
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
        let extracted = extractAnchors(
            from: rawTrimmed,
            vocabularyTerms: vocabularyTerms,
            translationExpected: translationExpected
        )
        let anchors = extracted.anchors
        let polishedLowercased = polishedTrimmed.lowercased()
        let polishedWithoutPunctuation = strippingPunctuation(polishedTrimmed).lowercased()
        let missing = anchors.filter {
            !$0.survives(inLiteral: polishedLowercased, withoutPunctuation: polishedWithoutPunctuation)
        }
        // Numbers must survive as an ordered, duplicate-aware subsequence (see
        // ExtractedAnchors): this catches a swap (5<->6) or a changed duplicate
        // (5+5 -> 5+15) that the per-anchor membership check above cannot.
        let numericMissing = missingNumericTokenCount(
            rawSequence: extracted.numericSequence, in: polishedTrimmed)

        // CJK targets compress a faithful translation well below the normal
        // floor, so lower the floor only when translating into a dense script
        // AND the output is actually dominantly dense (a half-translated mixed
        // output keeps the normal floor). The ceiling stays unconditional.
        let floor =
            (translationExpected && targetIsDenseScript
                && denseScriptFraction(of: polishedTrimmed) >= denseScriptFractionThreshold)
            ? denseScriptMinimumLengthRatio : minimumLengthRatio
        let ratioAcceptable = ratio >= floor && ratio <= maximumLengthRatio
        let missingCount = missing.count + numericMissing
        return PolishFidelityVerdict(
            isAcceptable: ratioAcceptable && missingCount == 0,
            lengthRatio: ratio,
            missingAnchors: missingCount,
            totalAnchors: anchors.count + extracted.numericSequence.count
        )
    }

    /// Anchors split into the deduplicated literal/capitalized/vocabulary set and
    /// the ordered numeric sequence. Numbers are kept ordered and duplicate-
    /// preserving (not deduplicated anchors) so a swap (5<->6) or a duplicate-
    /// count change (5+5 -> 5+15) is caught — a Set would silently lose both.
    struct ExtractedAnchors {
        let anchors: [Anchor]
        let numericSequence: [String]
    }

    /// Tokens that must survive a literal polish: numbers (as an ordered
    /// sequence), URLs, emails, identifier-like capitalized tokens, and
    /// vocabulary terms present in raw. Identifier-like words are skipped when a
    /// translation is expected — only translation-invariant anchors should
    /// survive across languages.
    static func extractAnchors(
        from raw: String,
        vocabularyTerms: [String],
        translationExpected: Bool = false
    ) -> ExtractedAnchors {
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

        // Numbers: an ordered, duplicate-preserving sequence (NOT deduplicated
        // anchors). orderedNumericTokens already drops digits embedded in URLs/
        // emails, which keep their own literal anchor below. Capped for bounded
        // work (an independent perf bound from the anchor cap).
        var numericSequence: [String] = []
        for token in orderedNumericTokens(in: raw) where !isExempt(token) {
            numericSequence.append(token)
            if numericSequence.count >= maximumAnchors { break }
        }

        for pattern in [emailPattern, urlPattern, wwwPattern] {
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

        return ExtractedAnchors(anchors: anchors, numericSequence: numericSequence)
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
                guard !capitalizedWordStopAnchors.contains(cleaned.lowercased()) else { continue }
                guard isProtectedCapitalizedToken(cleaned) else { continue }
                results.append(cleaned)
            }
        }
        return results
    }

    private static func isProtectedCapitalizedToken(_ word: String) -> Bool {
        let scalars = word.unicodeScalars
        let hasPunctuation = scalars.contains { CharacterSet.punctuationCharacters.contains($0) }
        let hasDigit = word.contains { $0.isNumber }
        if hasPunctuation || hasDigit { return true }

        let letters = word.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }

        let uppercaseCount = letters.filter { $0.isUppercase }.count
        let lowercaseCount = letters.filter { $0.isLowercase }.count
        if letters.count >= 3 && uppercaseCount == letters.count { return true }
        return uppercaseCount >= 2 && lowercaseCount > 0
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

    /// True when `value` reads as a number (digits plus the `.,:` separators the
    /// anchor regex allows), so its survival must respect digit boundaries.
    static func isNumericLiteral(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isNumber else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "," || $0 == ":") }
    }

    /// The whole numeric tokens in `text`, in document order WITH duplicates,
    /// lowercased. Digits embedded in URLs/emails are blanked first so a
    /// preserved-but-moved link does not feed the ordered numeric check (the link
    /// keeps its own literal anchor). A numeric token matches only as an exact
    /// token, so "5" does not match inside "15", "5.5", "5,000" or "5:30".
    static func orderedNumericTokens(in text: String) -> [String] {
        let withoutLinks =
            text
            .replacingOccurrences(of: emailPattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: urlPattern, with: " ", options: .regularExpression)
            .replacingOccurrences(of: wwwPattern, with: " ", options: .regularExpression)
        return matches(of: numericPattern, in: withoutLinks).map { $0.lowercased() }
    }

    /// Count of raw numeric tokens that do not survive as an ordered, duplicate-
    /// aware subsequence of the polished numeric tokens. Greedy first-match is
    /// optimal for subsequence containment (taking the earliest match never
    /// forecloses a later one), so it neither over- nor under-counts.
    static func missingNumericTokenCount(rawSequence: [String], in polished: String) -> Int {
        guard !rawSequence.isEmpty else { return 0 }
        let polishedTokens = orderedNumericTokens(in: polished)
        var index = 0
        var missing = 0
        for token in rawSequence {
            var matched = false
            while index < polishedTokens.count {
                let current = polishedTokens[index]
                index += 1
                if current == token {
                    matched = true
                    break
                }
            }
            if !matched { missing += 1 }
        }
        return missing
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
