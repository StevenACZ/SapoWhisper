//
//  WhisperHallucinationFilter.swift
//  SapoWhisper
//

import Foundation

/// Post-transcription hygiene for Whisper-family hallucinations on short or
/// near-silent takes, applied to every batch engine result. Three deterministic
/// failure shapes are handled (all reproduced from real history audio):
///
/// 1. Punctuation-only debris (". .") that survives the server's VAD.
/// 2. Repetition loops — the decoder locks onto one token or a short cycle
///    and repeats it for the rest of the window ("CTK214, .tk214, .tk214, …").
/// 3. Vocabulary echo — on breathy non-speech audio the decoder reads the
///    glossary initial prompt back as the transcript ("Sapo.md, CLAUDE.md,
///    CLAUDE.md, …"), sometimes with distorted spellings.
///
/// Free-phrase hallucinations ("Thank you.") are NOT handled here — they are
/// indistinguishable from real speech in text form. The server-side VAD filter
/// (`vad_filter=true`) is the layer that kills those before decoding.
enum WhisperHallucinationFilter {

    enum Outcome: Equatable {
        /// Clean transcript (repetition loops already collapsed).
        case speech(String)
        /// The text is hallucination debris; treat the take as silence.
        /// The reason is log-safe (static description + counts, no content).
        case nonSpeech(reason: String)
    }

    /// A single token must repeat this many times before it collapses —
    /// real speech repeats words ("no, no, no"), loops repeat far more.
    private static let minSingleTokenRepeats = 4
    /// Multi-token cycles are unnatural much earlier ("CLAUDE.md, Sapo.md" ×3).
    private static let minCycleRepeats = 3
    /// Longest token cycle the collapse scan looks for.
    private static let maxCycleLength = 4
    /// Similarity floor for matching a distorted echo token to a vocabulary
    /// term ("Yellyfin" vs "Jellyfin" = 0.88).
    private static let echoSimilarityThreshold = 0.75

    nonisolated static func evaluate(_ transcript: String, vocabularyTerms: [String]) -> Outcome {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
            return .nonSpeech(reason: "no alphanumeric content chars=\(trimmed.count)")
        }

        let collapse = collapsingRepetitionLoops(trimmed)
        guard collapse.collapsed else { return .speech(trimmed) }

        if isVocabularyEcho(collapse.text, vocabularyTerms: vocabularyTerms) {
            return .nonSpeech(reason: "vocabulary echo after loop collapse")
        }
        return .speech(collapse.text)
    }

    /// Collapses consecutive repeats of the same token (≥4) or token cycle
    /// (2-4 tokens, ≥3) down to a single occurrence. Comparison ignores case
    /// and surrounding punctuation, so ".tk214," and ".tk214." repeat-match.
    nonisolated static func collapsingRepetitionLoops(_ text: String) -> (text: String, collapsed: Bool) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= minSingleTokenRepeats else { return (text, false) }
        let keys = tokens.map(normalizedTokenKey)

        var kept: [String] = []
        var collapsed = false
        var index = 0
        while index < tokens.count {
            var advanced = false
            // Shortest cycle first finds the fundamental period: a uniform
            // run ("x x x x") collapses as one token, not as an "x x x x"
            // 4-cycle; alternating pairs only ever match at length 2.
            for cycleLength in 1...maxCycleLength {
                guard index + cycleLength <= tokens.count else { continue }
                let cycle = Array(keys[index..<(index + cycleLength)])
                guard !cycle.contains(where: \.isEmpty) else { continue }

                var repeats = 1
                var next = index + cycleLength
                while next + cycleLength <= tokens.count,
                    Array(keys[next..<(next + cycleLength)]) == cycle
                {
                    repeats += 1
                    next += cycleLength
                }

                let floor = cycleLength == 1 ? minSingleTokenRepeats : minCycleRepeats
                if repeats >= floor {
                    kept.append(contentsOf: tokens[index..<(index + cycleLength)])
                    collapsed = true
                    index = next
                    advanced = true
                    break
                }
            }
            if !advanced {
                kept.append(tokens[index])
                index += 1
            }
        }
        guard collapsed else { return (text, false) }

        var result = kept.joined(separator: " ")
        while let last = result.last, last == "," || last == ";" {
            result.removeLast()
        }
        return (result, true)
    }

    /// True when every comma-separated piece of the (already collapsed) text
    /// is a vocabulary term, a fusion of vocabulary terms ("Sapo.md"), or a
    /// near-miss spelling of one ("Yellyfin"). Requires at least two pieces so
    /// a genuine one-term dictation ("Jellyfin") always passes through.
    nonisolated static func isVocabularyEcho(_ text: String, vocabularyTerms: [String]) -> Bool {
        guard !vocabularyTerms.isEmpty else { return false }
        let pieces =
            text
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard pieces.count >= 2 else { return false }

        // "Glossary" is part of the prompt itself and echoes with the terms.
        let terms = (vocabularyTerms + ["Glossary"])
            .map { $0.lowercased() }
            .sorted { $0.count > $1.count }

        return pieces.allSatisfy { piece in
            let key = piece.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard key.rangeOfCharacter(from: .alphanumerics) != nil else { return true }

            // Fusion check: deleting every known term leaves no letters/digits.
            var residue = key
            for term in terms {
                residue = residue.replacingOccurrences(of: term, with: " ")
            }
            if residue.rangeOfCharacter(from: .alphanumerics) == nil { return true }

            // Distortion check: close enough to one term.
            return terms.contains { similarity($0, key) >= echoSimilarityThreshold }
        }
    }

    nonisolated private static func normalizedTokenKey(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Normalized Levenshtein similarity in 0...1.
    nonisolated private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let left = Array(a)
        let right = Array(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitution = previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        let distance = previous[right.count]
        return 1 - Double(distance) / Double(max(left.count, right.count))
    }
}
