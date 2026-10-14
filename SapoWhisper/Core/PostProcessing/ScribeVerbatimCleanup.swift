//
//  ScribeVerbatimCleanup.swift
//  SapoWhisper
//

import Foundation

/// Tidies ElevenLabs Scribe verbatim text. Scribe's `no_verbatim` flag also
/// drops real phrases from spontaneous dictations, so both Scribe endpoints
/// ask for verbatim text and this pass removes only what that flag was meant
/// to: fillers ("eh", "mmm", "um"), cut-off words Scribe marks with a trailing
/// "--", stretched vowels ("holaaa") and immediate word repeats ("el, el").
/// Digits never collapse: "4 4 5" is a dictated number, not a stutter, and a
/// filler shape right after a number is a unit ("5 mm").
nonisolated enum ScribeVerbatimCleanup {

    private struct Token {
        var lead: String
        var core: String
        var trail: String
    }

    private static let leadingMarks: Set<Character> = ["¿", "¡", "\"", "'", "(", "[", "«", "“"]
    private static let trailingMarks: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", "\"", "'", ")", "]", "»", "”",
    ]
    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…"]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "á", "é", "í", "ó", "ú"]
    /// Letter shapes after collapsing repeats: "eeehm" → "ehm", "hmm" → "hm".
    private static let fillerShapes: Set<String> = ["eh", "ehm", "em", "ah", "um", "uh", "uhm", "hm"]

    static func clean(_ text: String) -> String {
        var kept: [Token] = []
        var capitalizeNext = false
        var changed = false

        for raw in text.split(whereSeparator: \.isWhitespace) {
            var token = split(String(raw))
            let isUnit = kept.last.map { $0.trail.isEmpty && $0.core.contains(where: \.isNumber) } ?? false
            if raw.hasSuffix("--") || token.core.hasSuffix("--") || (isFiller(token.core) && !isUnit) {
                changed = true
                let atSentenceStart = kept.last.map { endsSentence($0.trail) } ?? true
                if atSentenceStart, token.core.first?.isUppercase == true {
                    capitalizeNext = true
                }
                let ends = token.trail.filter { sentenceEnds.contains($0) }
                if !ends.isEmpty, let last = kept.indices.last, !endsSentence(kept[last].trail) {
                    var trail = kept[last].trail
                    while let mark = trail.last, mark == "," || mark == ";" || mark == ":" {
                        trail.removeLast()
                    }
                    kept[last].trail = trail + ends
                }
                continue
            }

            let unstretched = collapsingStretchedVowels(token.core)
            if unstretched != token.core {
                token.core = unstretched
                changed = true
            }
            if let last = kept.indices.last, let key = wordKey(token.core), key == wordKey(kept[last].core),
                kept[last].trail.isEmpty || kept[last].trail == ","
            {
                kept[last].trail = token.trail
                changed = true
                continue
            }
            if capitalizeNext, let first = token.core.first, first.isLowercase {
                token.core = first.uppercased() + token.core.dropFirst()
            }
            capitalizeNext = false
            kept.append(token)
        }

        guard changed else { return text }
        return kept.map { $0.lead + $0.core + $0.trail }.joined(separator: " ")
    }

    private static func split(_ raw: String) -> Token {
        var core = Substring(raw)
        var lead = ""
        while let first = core.first, leadingMarks.contains(first) {
            lead.append(first)
            core.removeFirst()
        }
        var trail = ""
        while let last = core.last, trailingMarks.contains(last) {
            trail.insert(last, at: trail.startIndex)
            core.removeLast()
        }
        return Token(lead: lead, core: String(core), trail: trail)
    }

    private static func isFiller(_ core: String) -> Bool {
        var shape = ""
        var length = 0
        for character in core.lowercased() {
            length += 1
            if shape.last != character { shape.append(character) }
        }
        if fillerShapes.contains(shape) { return true }
        return (shape == "e" || shape == "m") && length >= 2
    }

    private static func endsSentence(_ trail: String) -> Bool {
        trail.contains { sentenceEnds.contains($0) }
    }

    private static func wordKey(_ core: String) -> String? {
        guard !core.isEmpty, core.allSatisfy(\.isLetter) else { return nil }
        return core.lowercased()
    }

    private static func collapsingStretchedVowels(_ word: String) -> String {
        let characters = Array(word)
        var result = ""
        var index = 0
        while index < characters.count {
            var end = index
            while end + 1 < characters.count, characters[end + 1] == characters[index] { end += 1 }
            if vowels.contains(characters[index]), end - index >= 2 {
                result.append(characters[index])
            } else {
                result.append(contentsOf: characters[index...end])
            }
            index = end + 1
        }
        return result
    }
}
