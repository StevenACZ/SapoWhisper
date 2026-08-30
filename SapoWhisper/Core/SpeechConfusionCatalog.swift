//
//  SpeechConfusionCatalog.swift
//  SapoWhisper
//

import Foundation

/// One source of truth for speech-mishearing data and spoken-form helpers,
/// shared by the two correction pipelines:
/// - `VocabularyManager` (deterministic recognition-correction pass), and
/// - `AIPolishMemoryManager` (correction-suggestion detection).
/// Both managers used to carry private copies of these tables, and the copies
/// drifted (the AI-memory one was missing half the brand variants). Add new
/// brand mishearings here so both pipelines see them.
nonisolated enum SpeechConfusionCatalog {

    /// Brand/product mishearing tables, applied by case-insensitive substring
    /// replacement over any term that contains the needle.
    static let brandVariants: [(needle: String, variants: [String])] = [
        ("Claude", ["Cloud", "Claw", "Clawd", "Clawed", "Claud", "Clauco", "Clouco", "Slough", "Clog"]),
        ("Deepgram", ["Deep gram", "Depgram", "Deppgram", "Ditgram"]),
        ("ElevenLabs", ["Eleven Labs", "11labs"]),
        ("CHANGELOG", ["Change log", "hangelog", "changelov"]),
        ("AGENTS.md", ["AGENTS punto eme de", "Ages punto eme de"]),
        ("Local AI Server", ["localize server", "local ya server", "localia server"]),
        (
            "SapoWhisper",
            [
                "Sapo Whisper",
                "Sapo Visper",
                "SAP OVISPER",
                "Sapa Whisper",
                "SAPA Whisper",
                "SAP Awhisper",
                "Zap o Whisper",
                "Zapo Whisper",
                "Sapowisper",
            ]
        ),
        ("Hetzner", ["Etzner", "Etsner", "Edsner", "Hedsner", "Headsnare", "Head snare", "HeadServe", "HeadServer"]),
        ("Jellyfin", ["Jellifin", "Gelifin", "Jellyfine", "JellyFight", "JellyFy"]),
        ("PostgreSQL", ["PostgresUL", "Postgres SQL"]),
        ("Cloudflare", ["ClavFlare", "CloudFair"]),
        ("WireGuard", ["YFWAR", "YF WAR", "WifeWare"]),
    ]

    /// Appends every brand-table variant that applies to `term` (terms that do
    /// not contain a needle are untouched).
    static func appendBrandVariants(for term: String, to forms: inout [String]) {
        for (needle, variants) in brandVariants {
            appendReplacementVariants(for: term, replacing: needle, with: variants, to: &forms)
        }
    }

    static func appendReplacementVariants(
        for term: String,
        replacing needle: String,
        with replacements: [String],
        to forms: inout [String]
    ) {
        guard term.range(of: needle, options: [.caseInsensitive]) != nil else { return }
        for replacement in replacements {
            forms.append(term.replacingOccurrences(of: needle, with: replacement, options: [.caseInsensitive]))
        }
    }

    /// "SapoWhisper" -> "Sapo Whisper", "claude.md" -> "claude md": separators
    /// become spaces and camel-case humps split the way narrators speak them.
    static func spokenForm(for term: String) -> String {
        let separated = term.replacingOccurrences(of: #"[-_.]+"#, with: " ", options: .regularExpression)
        let characters = Array(separated)
        guard characters.count > 1 else { return separated }

        var result = ""
        for index in characters.indices {
            let character = characters[index]
            if index > characters.startIndex {
                let previous = characters[characters.index(before: index)]
                let nextIndex = characters.index(after: index)
                let next = nextIndex < characters.endIndex ? characters[nextIndex] : nil
                if shouldInsertSpeechSpace(previous: previous, current: character, next: next) {
                    result.append(" ")
                }
            }
            result.append(character)
        }

        return result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    /// ".env" -> "dot env" (or "period env" / "punto env" via `symbolWord`).
    static func spokenSymbolForm(for term: String, symbolWord: String) -> String {
        term
            .replacingOccurrences(of: ".", with: " \(symbolWord) ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "git commit" -> "gitcommit": separators and spaces removed.
    static func condensedSymbolForm(for term: String) -> String {
        term.replacingOccurrences(of: #"[-_.\s]+"#, with: "", options: .regularExpression)
    }

    static func alphanumericTokens(in term: String) -> [String] {
        term.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func shouldInsertSpeechSpace(previous: Character, current: Character, next: Character?) -> Bool {
        guard current.isUppercase else { return false }
        if previous.isLowercase || previous.isNumber { return true }
        if previous.isUppercase, next?.isLowercase == true { return true }
        return false
    }
}
