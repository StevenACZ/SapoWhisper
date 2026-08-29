//
//  PolishFidelityGuard.swift
//  SapoWhisper
//

import Foundation
import NaturalLanguage

struct PolishFidelityVerdict {
    let isAcceptable: Bool
    let missingAnchors: Int
    let totalAnchors: Int
    let translationShapeMismatch: Bool
    /// May contain transcript tokens already sent to the polish provider.
    /// Use only inside a retry prompt; never log or persist it.
    let retryInstruction: String?

    /// Counts only — never transcript content.
    var diagnosticSummary: String {
        "missingAnchors=\(missingAnchors)/\(totalAnchors) translationShape=\(translationShapeMismatch ? "rejected" : "ok")"
    }
}

/// Minimal post-response check for hard tokens that should not silently change.
/// A failed verdict triggers regeneration but never raw-fallbacks the polish.
enum PolishFidelityGuard {
    /// One raw token that must survive a literal polish. `.literal` anchors
    /// (URLs, emails, paths, commands, and filenames) must appear verbatim.
    /// `.vocabulary` anchors match on
    /// word boundaries: substring matching would both create anchors from
    /// unrelated words ("git" inside "digital") and let unrelated words
    /// satisfy them, and the resulting false retries pressure the model into
    /// injecting terms the user never said. `.capitalizedWord` anchors
    /// (identifiers) also survive when only punctuation the polish
    /// legitimately fixes differs, so a dictation typo like `AGENTS..md` being
    /// corrected to `AGENTS.md` is not a false retry signal — while dropping
    /// the `md` content (→ `AGENTS`) still fails.
    struct Anchor {
        enum Kind { case literal, technicalLiteral, capitalizedWord, vocabulary }
        let value: String
        let kind: Kind

        func survives(inLiteral literal: String, lowercased: String, withoutPunctuation stripped: String) -> Bool {
            let needle = value.lowercased()
            switch kind {
            case .vocabulary:
                return PolishFidelityGuard.containsWholeTermCaseSensitive(value, in: literal)
            case .literal:
                return PolishFidelityGuard.containsExactLiteralToken(value, in: literal)
            case .technicalLiteral:
                return PolishFidelityGuard.containsExactTechnicalToken(value, in: literal)
            case .capitalizedWord:
                if lowercased.contains(needle) { return true }
                let key = PolishFidelityGuard.strippingPunctuation(value).lowercased()
                guard key.count >= 3 else { return false }
                return stripped.contains(key)
            }
        }
    }

    private static let emailPattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    private static let urlPattern = #"https?://[^\s]+"#
    private static let wwwPattern = #"\bwww\.[^\s]+"#
    private static let pathPattern = #"(?<![:/\p{L}\p{N}_])(?:~/|\.{1,2}/|/)(?:[A-Za-z0-9_@%+,:=-]+/)*[A-Za-z0-9._@%+,:=-]+"#
    private static let filenamePattern =
        #"(?:(?<![\p{L}\p{N}_/.])\.[A-Za-z][A-Za-z0-9_-]*|(?<![\p{L}\p{N}_/])(?=[A-Za-z0-9_-]*[A-Za-z_])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+)(?![\p{L}\p{N}_/])"#
    private static let commandFlagPattern = #"(?<![\p{L}\p{N}_-])--?[A-Za-z0-9][A-Za-z0-9_-]*"#
    private static let technicalTokenPattern =
        #"\b(?:[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+|[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9-]+|[A-Za-z][A-Za-z0-9._-]*/[A-Za-z0-9._/-]+)\b"#
    private static let alphanumericIdentifierPattern =
        #"\b(?=[A-Za-z0-9._-]*[A-Za-z])(?=[A-Za-z0-9._-]*\d)[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*\b"#
    private static let contextualCommandPattern =
        #"\b(?:ejecuta|ejecutar|corre|correr|usa|run|execute|use|command)\s+(?:(?:el|the)\s+)?(?:(?:comando|command)\s+)?(rm|cp|mv|rsync|scp|ssh|curl|make|git|npm|pnpm|yarn|swift|docker|kubectl|brew|python3?|node|bash|zsh)\b"#
    private static let shellCommandPatterns = [
        #"\bgit\s+(?:push|pull)(?:\s+--?[A-Za-z0-9_-]+)*(?:\s+[A-Za-z0-9._/@:+-]+){0,2}"#,
        #"\bgit\s+(?:fetch|checkout|switch|merge|rebase|commit|status|add|restore|reset|diff|log)(?:\s+--?[A-Za-z0-9_-]+)*(?:\s+[A-Za-z0-9._/@:+-]+)?"#,
        #"\b(?:npm|pnpm|yarn)\s+(?:run\s+)?[A-Za-z0-9._:@+-]+"#,
        #"\bswift\s+(?:build|test|run|package)\b"#,
        #"\b(?:docker|kubectl|brew)\s+(?:build|run|pull|push|apply|delete|install|uninstall|upgrade)(?:\s+[A-Za-z0-9._/@:+-]+)?"#,
        #"\b(?:python3?|node|bash|zsh)\s+(?:--?[A-Za-z0-9_-]+\s+)*(?:\.{0,2}/|~/)?[A-Za-z0-9_/-]+\.(?:py|js|sh)\b"#,
    ]

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

    /// `translationExpected` relaxes identifier anchors: a requested output
    /// language legitimately rewrites regular words, so only clear literal
    /// technical anchors and vocabulary should trigger a retry.
    static func evaluate(
        raw: String,
        polished: String,
        vocabularyTerms: [String],
        translationExpected: Bool = false,
        compactionExpected: Bool = false
    ) -> PolishFidelityVerdict {
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let polishedTrimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmed.isEmpty else {
            return PolishFidelityVerdict(
                isAcceptable: false,
                missingAnchors: 0,
                totalAnchors: 0,
                translationShapeMismatch: false,
                retryInstruction: "Regenerate the polished transcript from the original text."
            )
        }

        let extracted = extractAnchors(
            from: rawTrimmed,
            vocabularyTerms: vocabularyTerms,
            translationExpected: translationExpected
        )
        let anchors = extracted.anchors
        let polishedLowercased = polishedTrimmed.lowercased()
        let polishedWithoutPunctuation = strippingPunctuation(polishedTrimmed).lowercased()
        let missing = anchors.filter {
            !$0.survives(
                inLiteral: polishedTrimmed,
                lowercased: polishedLowercased,
                withoutPunctuation: polishedWithoutPunctuation
            )
        }
        let missingCount = missing.count
        let translationShapeMismatch =
            translationExpected
            && !translationShapeIsPlausible(
                raw: rawTrimmed,
                polished: polishedTrimmed,
                compactionExpected: compactionExpected
            )
        return PolishFidelityVerdict(
            isAcceptable: missingCount == 0 && !translationShapeMismatch,
            missingAnchors: missingCount,
            totalAnchors: anchors.count,
            translationShapeMismatch: translationShapeMismatch,
            retryInstruction: retryInstruction(for: missing, translationShapeMismatch: translationShapeMismatch)
        )
    }

    private static func translationShapeIsPlausible(
        raw: String,
        polished: String,
        compactionExpected: Bool
    ) -> Bool {
        let rawUnits = lexicalUnitCount(in: raw)
        let polishedUnits = lexicalUnitCount(in: polished)
        guard rawUnits > 0 else { return polishedUnits > 0 }
        guard polishedUnits > 0 else { return false }

        let ratio = Double(polishedUnits) / Double(rawUnits)
        let lowerBound = compactionExpected ? 0.10 : (rawUnits >= 8 ? 0.30 : 0.20)
        let upperBound = rawUnits >= 8 ? 4.0 : 5.0
        return ratio >= lowerBound && ratio <= upperBound
    }

    private static func lexicalUnitCount(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// Anchors split into the deduplicated literal/capitalized/vocabulary set.
    struct ExtractedAnchors {
        let anchors: [Anchor]
    }

    /// Tokens that should survive a polish retry: literal technical tokens,
    /// identifier-like capitalized tokens, and vocabulary terms present in raw.
    static func extractAnchors(
        from raw: String,
        vocabularyTerms: [String],
        translationExpected: Bool = false
    ) -> ExtractedAnchors {
        var anchors: [Anchor] = []
        var seen = Set<String>()
        var coveredTechnicalRanges: [NSRange] = []

        func add(_ anchor: String, kind: Anchor.Kind, range: NSRange? = nil) {
            let trimmed = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { return }
            if case .technicalLiteral = kind, let range,
                coveredTechnicalRanges.contains(where: {
                    $0.location <= range.location && NSMaxRange($0) >= NSMaxRange(range)
                        && $0.length > range.length
                })
            {
                return
            }
            seen.insert(key)
            anchors.append(Anchor(value: trimmed, kind: kind))
            if let range {
                switch kind {
                case .literal, .technicalLiteral:
                    coveredTechnicalRanges.append(range)
                case .capitalizedWord, .vocabulary:
                    break
                }
            }
        }

        let exemptSegments = selfCorrectionExemptSegments(in: raw)
        func isExempt(_ candidate: String) -> Bool {
            let lowered = candidate.lowercased()
            let rawCount = occurrenceCount(of: lowered, in: raw.lowercased())
            let exemptCount = exemptSegments.reduce(0) { $0 + occurrenceCount(of: lowered, in: $1) }
            return rawCount > 0 && exemptCount >= rawCount
        }

        for pattern in [emailPattern, urlPattern, wwwPattern] {
            for match in matches(of: pattern, in: raw) {
                let anchor = trimmingTrailingPunctuation(match.value)
                guard !isExempt(anchor) else { continue }
                add(anchor, kind: .literal, range: match.range)
            }
        }

        for pattern in shellCommandPatterns + [
            pathPattern, filenamePattern, commandFlagPattern, technicalTokenPattern, alphanumericIdentifierPattern,
        ] {
            for match in matches(of: pattern, in: raw) {
                let anchor = trimmingTrailingPunctuation(match.value)
                guard !isExempt(anchor) else { continue }
                add(anchor, kind: .technicalLiteral, range: match.range)
            }
        }
        for command in capturedMatches(of: contextualCommandPattern, capture: 1, in: raw)
        where !isExempt(command.value) {
            add(command.value, kind: .technicalLiteral, range: command.range)
        }

        if !translationExpected {
            for word in midSentenceCapitalizedWords(in: raw) where !isExempt(word) {
                add(word, kind: .capitalizedWord)
            }
        }

        for term in vocabularyTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, containsWholeTerm(trimmed, in: raw) else { continue }
            add(trimmed, kind: .vocabulary)
        }

        return ExtractedAnchors(anchors: anchors)
    }

    /// Case-insensitive whole-term match: the term must not be glued to
    /// letters or digits on either side, so "git" neither anchors from nor
    /// survives inside "digital".
    static func containsWholeTerm(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsWholeTermCaseSensitive(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsExactTechnicalToken(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?<![\p{L}\p{N}._/-])"# + escaped + #"(?![\p{L}\p{N}._/-])"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsExactLiteralToken(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern =
            #"(?<![\p{L}\p{N}._@%+:/?#=&-])"# + escaped
            + #"(?![\p{L}\p{N}_@%+:/?#=&-]|\.(?=[\p{L}\p{N}]))"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Sentence punctuation glued to a URL/email match ("https://x.com/foo,")
    /// is not part of the token; anchoring it forces a false retry whenever
    /// the polish fixes the punctuation. A closing parenthesis only stays when
    /// the token itself opened one.
    private static func trimmingTrailingPunctuation(_ token: String) -> String {
        var trimmed = Substring(token)
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "\"", "'", "»", "”", "’"]
        while let last = trimmed.last, trailing.contains(last) {
            if last == ")", trimmed.contains("(") { break }
            if last == "]", trimmed.contains("[") { break }
            if last == "}", trimmed.contains("{") { break }
            trimmed = trimmed.dropLast()
        }
        return String(trimmed)
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

    /// Lowercased raw substrings spanning the immediate characters before each
    /// self-correction marker (plus the marker itself).
    private static func selfCorrectionExemptSegments(in raw: String) -> [String] {
        let lowercased = raw.lowercased()
        var segments: [String] = []
        for marker in selfCorrectionMarkers {
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let pattern = #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
            for match in regex.matches(in: lowercased, range: fullRange) {
                guard let found = Range(match.range, in: lowercased) else { continue }
                let windowStart =
                    lowercased.index(found.lowerBound, offsetBy: -28, limitedBy: lowercased.startIndex)
                    ?? lowercased.startIndex
                segments.append(String(lowercased[windowStart..<found.upperBound]))
            }
        }
        return segments
    }

    private static func retryInstruction(for missing: [Anchor], translationShapeMismatch: Bool) -> String? {
        guard !missing.isEmpty || translationShapeMismatch else { return nil }
        var requirements: [String] = []
        if !missing.isEmpty {
            let protectedTokens = missing.prefix(12)
                .map { "\"\(promptSafeAnchor($0.value))\"" }
                .joined(separator: ", ")
            let suffix = missing.count > 12 ? ", and \(missing.count - 12) more" : ""
            requirements.append("preserve these exact tokens: \(protectedTokens)\(suffix)")
        }
        if translationShapeMismatch {
            requirements.append("translate the complete transcript without collapsing it or adding an expanded answer")
        }
        return
            "A previous polish attempt changed or omitted real content. Regenerate the full text and \(requirements.joined(separator: "; ")). Return ONLY the final polished transcript."
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

    private struct TextMatch {
        let value: String
        let range: NSRange
    }

    private static func matches(of pattern: String, in text: String) -> [TextMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range, in: text).map { TextMatch(value: String(text[$0]), range: match.range) }
        }
    }

    private static func capturedMatches(of pattern: String, capture: Int, in text: String) -> [TextMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard capture < match.numberOfRanges, let range = Range(match.range(at: capture), in: text) else {
                return nil
            }
            return TextMatch(value: String(text[range]), range: match.range(at: capture))
        }
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
            let range = text.range(of: needle, range: searchStart..<text.endIndex)
        {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// Removes Unicode punctuation while preserving whitespace, letters, and
    /// digits, so a capitalized-word anchor can be compared tolerantly to the
    /// punctuation a polish legitimately fixes (`AGENTS..md` vs `AGENTS.md`).
    static func strippingPunctuation(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

}
