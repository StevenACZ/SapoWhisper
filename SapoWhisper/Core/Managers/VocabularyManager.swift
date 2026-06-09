//
//  VocabularyManager.swift
//  SapoWhisper
//

import Combine
import Foundation

/// ElevenLabs keyterm biasing limits, shared by the request builders and the
/// vocabulary UI so over-limit terms are surfaced instead of silently dropped.
enum ElevenLabsKeytermLimits {
    static let batchMaxCount = 1000
    static let batchMaxLength = 50
    static let batchMaxWords = 5
    static let realtimeMaxCount = 50
    static let realtimeMaxLength = 20
}

/// Manages keyterms and replacements for speech recognition engines.
/// Persists to ~/Library/Application Support/SapoWhisper/vocabulary.json
class VocabularyManager: ObservableObject {

    static let shared = VocabularyManager()

    @Published private(set) var keyterms: [String] = []
    @Published private(set) var replacements: [String: String] = [:]

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("vocabulary.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        keyterms = (json["keyterms"] as? [String]) ?? []
        replacements = (json["replacements"] as? [String: String]) ?? [:]
    }

    private func save() {
        let json: [String: Any] = [
            "keyterms": keyterms,
            "replacements": replacements,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        try? data.write(to: fileURL)
    }

    // MARK: - Keyterms CRUD

    func addKeyterm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !keyterms.contains(trimmed) else { return }
        keyterms.append(trimmed)
        save()
    }

    func removeKeyterm(at index: Int) {
        guard keyterms.indices.contains(index) else { return }
        keyterms.remove(at: index)
        save()
    }

    func removeKeyterm(_ term: String) {
        keyterms.removeAll { $0 == term }
        save()
    }

    // MARK: - Replacements CRUD

    func addReplacement(from original: String, to replacement: String) {
        let key = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return }
        replacements[key] = value
        save()
    }

    func removeReplacement(forKey key: String) {
        replacements.removeValue(forKey: key)
        save()
    }

    // MARK: - Import / Export

    func snapshot() -> VocabularySnapshot {
        VocabularySnapshot(keyterms: keyterms, replacements: replacements)
    }

    func merge(snapshot: VocabularySnapshot) {
        for term in snapshot.keyterms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !keyterms.contains(trimmed) else { continue }
            keyterms.append(trimmed)
        }

        for (original, replacement) in snapshot.replacements {
            let key = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            replacements[key] = value
        }

        save()
    }

    // MARK: - Limit validation

    /// Saved keyterms that exceed an ElevenLabs limit and would be dropped at
    /// request time. Counted here so the UI can warn instead of staying silent.
    func elevenLabsLimitViolations() -> (batch: Int, realtime: Int) {
        let trimmed =
            keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let batch = trimmed.filter {
            $0.count > ElevenLabsKeytermLimits.batchMaxLength
                || $0.split(separator: " ").count > ElevenLabsKeytermLimits.batchMaxWords
        }.count
        let realtime = trimmed.filter { $0.count > ElevenLabsKeytermLimits.realtimeMaxLength }.count
        return (batch, realtime)
    }

    // MARK: - Query Parameters for Deepgram

    /// Returns keyterm query items for Deepgram batch REST requests
    func keytermQueryItems() -> [URLQueryItem] {
        keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
    }

    /// Returns replace query items for Deepgram batch REST requests
    func replaceQueryItems() -> [URLQueryItem] {
        replacements.map { URLQueryItem(name: "replace", value: "\($0.key):\($0.value)") }
    }

    /// Applies saved replacements locally for engines that do not expose replace in their API surface.
    func applyingReplacements(to transcript: String) -> String {
        replacements
            .sorted { $0.key.count > $1.key.count }
            .reduce(transcript) { current, replacement in
                let pattern = Self.replacementPattern(for: replacement.key)
                guard
                    let regex = try? NSRegularExpression(
                        pattern: pattern,
                        options: [.caseInsensitive]
                    )
                else {
                    return current
                }

                let range = NSRange(current.startIndex..<current.endIndex, in: current)
                let replacementTemplate = NSRegularExpression.escapedTemplate(for: replacement.value)
                return regex.stringByReplacingMatches(
                    in: current,
                    options: [],
                    range: range,
                    withTemplate: replacementTemplate
                )
            }
    }

    /// Returns keyterms shaped for engines that accept server-side recognition hints.
    func recognitionKeytermPayload(
        maxCount: Int,
        maxLength: Int,
        maxWords: Int? = nil,
        includeReplacementValues: Bool = false
    ) -> (terms: [String], droppedCount: Int) {
        let candidates = recognitionCandidates(includeReplacementValues: includeReplacementValues)
        var seen = Set<String>()
        var expandedTerms: [String] = []

        func appendUnique(_ term: String) {
            let trimmed = Self.sanitizedRecognitionHint(term)
            guard !trimmed.isEmpty else { return }
            let normalized = trimmed.lowercased()
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            expandedTerms.append(trimmed)
        }

        for candidate in candidates {
            appendUnique(candidate)
        }

        for candidate in candidates {
            for variant in Self.recognitionVariants(for: candidate) {
                appendUnique(variant)
            }
        }

        let validTerms = expandedTerms.filter { term in
            term.count <= maxLength && (maxWords.map { term.split(separator: " ").count <= $0 } ?? true)
        }
        let terms = Array(validTerms.prefix(maxCount))
        return (terms, max(0, expandedTerms.count - terms.count))
    }

    /// Applies saved replacements and high-confidence vocabulary spelling corrections.
    func applyingRecognitionCorrections(to transcript: String) -> String {
        let replacedTranscript = applyingReplacements(to: transcript)
        let correctionPairs =
            recognitionCandidates(includeReplacementValues: true)
            .flatMap { keyterm in
                Self.correctionVariants(for: keyterm).map { variant in
                    (variant: variant, canonical: keyterm)
                }
            }
            .filter { $0.variant.compare($0.canonical, options: [.caseInsensitive]) != .orderedSame }
            .sorted { $0.variant.count > $1.variant.count }

        return correctionPairs.reduce(replacedTranscript) { current, pair in
            let pattern = Self.wholeTermPattern(for: pair.variant)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return current
            }

            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            let replacementTemplate = NSRegularExpression.escapedTemplate(for: pair.canonical)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: replacementTemplate
            )
        }
    }

    private func recognitionCandidates(includeReplacementValues: Bool) -> [String] {
        let savedKeyterms =
            keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard includeReplacementValues else { return savedKeyterms }

        let replacementValues =
            replacements
            .sorted { $0.key < $1.key }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return savedKeyterms + replacementValues
    }

    private static func recognitionVariants(for keyterm: String) -> [String] {
        uniqueVariants([
            keyterm,
            spokenForm(for: keyterm),
            spokenSymbolForm(for: keyterm),
        ])
    }

    private static func correctionVariants(for keyterm: String) -> [String] {
        recognitionVariants(for: keyterm)
    }

    private static func spokenForm(for keyterm: String) -> String {
        let separated = keyterm.replacingOccurrences(of: #"[-_.]+"#, with: " ", options: .regularExpression)
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

    private static func replacementPattern(for term: String) -> String {
        guard term.contains(where: { ".-_".contains($0) }) else {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return "\\b\(escaped)\\b"
        }

        let body = term.map { character -> String in
            switch character {
            case ".":
                return #"(?:\s*(?:\.|dot)?\s*)"#
            case "-":
                return #"(?:\s*(?:-|dash|hyphen)?\s*)"#
            case "_":
                return #"(?:\s*(?:_|underscore)?\s*)"#
            default:
                return NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        .joined()

        return "(?<![A-Za-z0-9])\(body)(?![A-Za-z0-9])"
    }

    private static func spokenSymbolForm(for keyterm: String) -> String {
        keyterm
            .replacingOccurrences(of: ".", with: " dot ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    private static func sanitizedRecognitionHint(_ term: String) -> String {
        String(
            term.unicodeScalars.map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            }
        )
        .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldInsertSpeechSpace(previous: Character, current: Character, next: Character?) -> Bool {
        guard current.isUppercase else { return false }
        if previous.isLowercase || previous.isNumber { return true }
        if previous.isUppercase, next?.isLowercase == true { return true }
        return false
    }

    private static func wholeTermPattern(for term: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
    }

    private static func uniqueVariants(_ variants: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for variant in variants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(trimmed)
        }

        return result
    }
}
