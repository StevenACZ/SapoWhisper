//
//  PolishContentDiffGuard.swift
//  SapoWhisper
//

import Foundation

struct PolishContentDiffVerdict {
    let isAcceptable: Bool
    let lostDigitRuns: Int
    let droppedClusters: Int
    /// May contain transcript tokens already sent to the polish provider.
    /// Use only inside a retry prompt; never log or persist it.
    let retryInstruction: String?

    /// Counts only — never transcript content.
    var diagnosticSummary: String {
        "lostDigits=\(lostDigitRuns) droppedClusters=\(droppedClusters)"
    }
}

/// Cheap deterministic raw-vs-polished diff: catches a polish that dropped
/// digits or an entire passage. A failed verdict triggers regeneration but
/// never raw-fallbacks the polish.
///
/// Numbers stay out of the hard-anchor guard on purpose (STT mangles spoken
/// numbers and the polish must be free to repair separators); this check is
/// the lenient complement: a digit run may be re-punctuated ("0,63" → "0.63")
/// or absorbed into a longer surviving run (stutter "14 ca--, 1440" → "1440"),
/// but digits that vanish entirely are a real loss.
enum PolishContentDiffGuard {
    private static let minimumClusterWords = 8
    private static let minimumDistinctiveTokens = 4
    private static let clusterSurvivalThreshold = 0.15
    private static let instructionSurvivalThreshold = 0.5
    private static let distinctiveTokenMinimumLength = 5
    private static let instructionPatterns = [
        #"\b(dime|cuentame|explicame|responde|investiga|busca|consulta|analiza|revisa|haz|crea|genera|calcula|corre|ejecuta|abre|instala|soluciona|arregla|dame|prepara|escribe|redacta|elimina|borra|mueve|cambia|actualiza|configura|guarda|copia|pega|sube|publica|despliega|prueba|verifica|documenta|agrega|anade|quita|remueve|renombra|reemplaza|compila|construye|inicia|deten|reinicia|avisale|recuerdale|mandale|deja)\b"#,
        #"\b(tell me|explain|answer|research|search|look up|analyze|analyse|review|run|execute|open|install|fix|create|generate|calculate|write|draft|delete|remove|move|change|update|configure|save|copy|paste|upload|publish|deploy|test|verify|document|add|rename|replace|build|start|stop|restart)\b"#,
        #"\b(necesito que|quiero que|tienes que|hay que|por favor|please|can you|could you|i need you to|i want you to|make sure to|make sure that)\b"#,
    ]

    /// `translationExpected` skips the content-cluster check — words
    /// legitimately change language — while digit runs must survive any
    /// translation. `compactionExpected` (compact polish mode) also skips the
    /// cluster check: dropping whole rambling passages is the mode's job, but
    /// digits must still survive compression.
    static func evaluate(
        raw: String,
        polished: String,
        translationExpected: Bool = false,
        compactionExpected: Bool = false
    ) -> PolishContentDiffVerdict {
        let lostRuns = lostDigitRuns(raw: raw, polished: polished)
        let dropped =
            translationExpected || compactionExpected
            ? [] : droppedClusters(raw: raw, polished: polished)
        return PolishContentDiffVerdict(
            isAcceptable: lostRuns.isEmpty && dropped.isEmpty,
            lostDigitRuns: lostRuns.count,
            droppedClusters: dropped.count,
            retryInstruction: retryInstruction(lostRuns: lostRuns, droppedClusters: dropped)
        )
    }

    private static func lostDigitRuns(raw: String, polished: String) -> [String] {
        let rawRuns = Set(digitRuns(in: raw))
        guard !rawRuns.isEmpty else { return [] }
        let polishedRuns = digitRuns(in: polished)
        let polishedSet = Set(polishedRuns)
        return rawRuns.filter { run in
            guard !polishedSet.contains(run) else { return false }
            return !polishedRuns.contains { $0.contains(run) }
        }.sorted()
    }

    private static func digitRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    /// Raw sentences whose distinctive words are almost entirely absent from
    /// the polished text — the signature of a dropped passage. Repetition
    /// merging passes because the kept copy still carries the words.
    private static func droppedClusters(raw: String, polished: String) -> [String] {
        let polishedLowercased = polished.lowercased()
        var dropped: [String] = []
        for sentence in sentences(in: raw) {
            let wordCount = sentence.split(separator: " ", omittingEmptySubsequences: true).count
            guard wordCount >= minimumClusterWords else { continue }
            let distinctive = distinctiveTokens(in: sentence)
            guard distinctive.count >= minimumDistinctiveTokens else { continue }
            let surviving = distinctive.filter { polishedLowercased.contains($0) }.count
            let threshold = containsInstructionCue(sentence) ? instructionSurvivalThreshold : clusterSurvivalThreshold
            if Double(surviving) / Double(distinctive.count) < threshold {
                dropped.append(sentence)
            }
        }
        return dropped
    }

    private static func sentences(in text: String) -> [String] {
        var results: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            let nextIndex = text.index(after: index)
            if ".!?…".contains(character) {
                let next = nextIndex < text.endIndex ? text[nextIndex] : " "
                if next.isWhitespace {
                    results.append(current)
                    current = ""
                }
            }
            index = nextIndex
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(current)
        }
        return results
    }

    private static func distinctiveTokens(in sentence: String) -> Set<String> {
        var tokens = Set<String>()
        for word in sentence.lowercased().split(separator: " ", omittingEmptySubsequences: true) {
            let cleaned = word.filter { $0.isLetter }
            if cleaned.count >= distinctiveTokenMinimumLength {
                tokens.insert(String(cleaned))
            }
        }
        return tokens
    }

    private static func containsInstructionCue(_ sentence: String) -> Bool {
        let normalized =
            sentence
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return instructionPatterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    private static func retryInstruction(lostRuns: [String], droppedClusters: [String]) -> String? {
        guard !lostRuns.isEmpty || !droppedClusters.isEmpty else { return nil }
        var parts: [String] = []
        if !lostRuns.isEmpty {
            let digits = lostRuns.prefix(8).map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("it lost numbers containing these digits: \(digits)")
        }
        if !droppedClusters.isEmpty {
            parts.append("it dropped \(droppedClusters.count) whole passage(s) of the transcript")
        }
        return """
            A previous polish attempt removed real content — \(parts.joined(separator: "; and ")). Regenerate the full polished text from the original transcript: keep every number exactly (digits as digits) and keep every distinct idea and instruction; only filler and repeated wording may be removed. Return ONLY the final polished transcript.
            """
    }
}
