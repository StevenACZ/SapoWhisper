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
    /// May contain transcript tokens already sent to the polish provider.
    /// Use only inside a retry prompt; never log or persist it.
    let retryInstruction: String?

    /// Counts only — never transcript content.
    var diagnosticSummary: String {
        String(format: "ratio=%.2f missingAnchors=%d/%d", lengthRatio, missingAnchors, totalAnchors)
    }
}

/// Minimal post-response check for hard tokens that should not silently change.
/// The result is a retry signal, not a user-facing blocker: regular wording,
/// numbers, length ratio, cleanup, and translation choices are left to the AI
/// prompt and the user's review.
enum PolishFidelityGuard {
    /// One raw token that must survive a literal polish. `.literal` anchors
    /// (URLs, emails, vocabulary) must appear verbatim. `.capitalizedWord`
    /// anchors (identifiers) also survive when only punctuation the polish
    /// legitimately fixes differs, so a dictation typo like `AGENTS..md` being
    /// corrected to `AGENTS.md` is not a false retry signal — while dropping
    /// the `md` content (→ `AGENTS`) still fails.
    struct Anchor {
        enum Kind { case literal, capitalizedWord }
        let value: String
        let kind: Kind

        func survives(inLiteral literal: String, withoutPunctuation stripped: String) -> Bool {
            let needle = value.lowercased()
            if literal.contains(needle) { return true }
            guard kind == .capitalizedWord else { return false }
            let key = PolishFidelityGuard.strippingPunctuation(value).lowercased()
            guard key.count >= 3 else { return false }
            return stripped.contains(key)
        }
    }

    private static let maximumAnchors = 60

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
    private static let accidentalRepeatedFillerPattern =
        #"(?:\b(?:ya\s+est[aá]|listo|dale|ok(?:ay)?|perfecto|eso)\b[\s.,;:!?¡¿-]*){4,}"#

    /// `translationExpected` relaxes identifier anchors: a requested output
    /// language legitimately rewrites regular words, so only clear literal
    /// anchors (URLs, emails, vocabulary) should trigger a retry.
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
            return PolishFidelityVerdict(
                isAcceptable: false,
                lengthRatio: 0,
                missingAnchors: 0,
                totalAnchors: 0,
                retryInstruction: "Regenerate the polished transcript from the original text."
            )
        }

        let ratioSource = lengthRatioSourceText(for: rawTrimmed)
        let ratio = Double(polishedTrimmed.count) / Double(ratioSource.count)
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
        let missingCount = missing.count
        return PolishFidelityVerdict(
            isAcceptable: missingCount == 0,
            lengthRatio: ratio,
            missingAnchors: missingCount,
            totalAnchors: anchors.count,
            retryInstruction: retryInstruction(for: missing)
        )
    }

    /// Anchors split into the deduplicated literal/capitalized/vocabulary set.
    struct ExtractedAnchors {
        let anchors: [Anchor]
    }

    /// Tokens that should survive a polish retry: URLs, emails, identifier-like
    /// capitalized tokens, and vocabulary terms present in raw. Identifier-like
    /// words are skipped when a translation is expected — only clear literal
    /// anchors should survive across languages.
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

        return ExtractedAnchors(anchors: anchors)
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

    /// Closing fillers can repeat dozens of times when dictation stops late
    /// ("ya está ya está..."). Collapse only known filler phrases for the length
    /// ratio, while anchors still come from the untouched raw transcript.
    private static func lengthRatioSourceText(for raw: String) -> String {
        let collapsed = raw.replacingOccurrences(
            of: accidentalRepeatedFillerPattern,
            with: " filler ",
            options: [.regularExpression, .caseInsensitive]
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    private static func retryInstruction(for missing: [Anchor]) -> String? {
        guard !missing.isEmpty else { return nil }
        let protectedTokens = missing.prefix(12)
            .map { "\"\(promptSafeAnchor($0.value))\"" }
            .joined(separator: ", ")
        let suffix = missing.count > 12 ? ", and \(missing.count - 12) more" : ""
        return """
            A previous polish attempt removed or changed protected tokens. Regenerate the full polished text from the original transcript and preserve these exact tokens: \(protectedTokens)\(suffix). Return ONLY the final polished transcript.
            """
    }

    private static func promptSafeAnchor(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

}
