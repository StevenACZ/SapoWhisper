//
//  AIPolishMemoryManager.swift
//  SapoWhisper
//

import Combine
import Foundation

enum AIPolishSuggestionStatus: String, Codable, Equatable {
    case pending
    case accepted
    case rejected
}

struct AIPolishCorrectionSuggestion: Codable, Equatable, Identifiable {
    let id: String
    var from: String
    var to: String
    var status: AIPolishSuggestionStatus
    var occurrences: Int
    var confidence: Double
    var firstSeen: Date
    var lastSeen: Date
}

final class AIPolishMemoryManager: ObservableObject {
    static let shared = AIPolishMemoryManager()

    @Published private(set) var pendingSuggestions: [AIPolishCorrectionSuggestion] = []
    @Published private(set) var acceptedSuggestions: [AIPolishCorrectionSuggestion] = []

    private let fileURL: URL
    private let lock = NSRecursiveLock()
    private var store: Store

    init(fileURL: URL, calendar _: Calendar = .current) {
        self.fileURL = fileURL
        self.store = Self.loadStore(from: fileURL)
        self.pendingSuggestions = Self.visiblePendingSuggestions(from: store)
        self.acceptedSuggestions = Self.visibleAcceptedSuggestions(from: store)
    }

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.init(fileURL: appDir.appendingPathComponent("ai-polish-memory.json"))
    }

    /// Accepted correction suggestions as heard→intended pairs, ready to merge
    /// into the user's replacements for the polish dictionary section.
    func acceptedReplacementPairs(limit: Int = 12) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        var pairs: [String: String] = [:]
        for suggestion in suggestions(status: .accepted, limit: limit) {
            pairs[suggestion.from] = suggestion.to
        }
        return pairs
    }

    func record(
        observedRawText: String,
        correctedText: String,
        finalText: String,
        status: TranscriptAIStatus,
        keyterms: [String],
        replacements: [String: String],
        now: Date = Date()
    ) {
        let raw = observedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || !final.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        store.lastUpdated = now
        store.totalTranscripts += 1

        recordCorrectionSuggestions(
            observedRawText: raw,
            correctedText: corrected,
            finalText: final,
            status: status,
            keyterms: keyterms,
            replacements: replacements,
            now: now
        )
        prune(now: now)
        save()
        publishSuggestions()
    }

    @discardableResult
    func acceptSuggestion(id: String) -> AIPolishCorrectionSuggestion? {
        updateSuggestion(id: id, status: .accepted)
    }

    @discardableResult
    func rejectSuggestion(id: String) -> AIPolishCorrectionSuggestion? {
        updateSuggestion(id: id, status: .rejected)
    }

    @discardableResult
    func deleteSuggestion(id: String) -> AIPolishCorrectionSuggestion? {
        lock.lock()
        defer { lock.unlock() }
        let removed = store.correctionSuggestions.removeValue(forKey: id)
        save()
        publishSuggestions()
        return removed
    }

    func snapshot() -> (terms: [String], suggestions: [AIPolishCorrectionSuggestion]) {
        lock.lock()
        defer { lock.unlock() }
        return (
            terms: [],
            suggestions: store.correctionSuggestions.values.sorted { $0.lastSeen > $1.lastSeen }
        )
    }

    private func updateSuggestion(id: String, status: AIPolishSuggestionStatus) -> AIPolishCorrectionSuggestion? {
        lock.lock()
        defer { lock.unlock() }
        guard var suggestion = store.correctionSuggestions[id] else { return nil }
        suggestion.status = status
        suggestion.lastSeen = Date()
        store.correctionSuggestions[id] = suggestion
        save()
        publishSuggestions()
        return suggestion
    }

    private func recordCorrectionSuggestions(
        observedRawText: String,
        correctedText: String,
        finalText: String,
        status: TranscriptAIStatus,
        keyterms: [String],
        replacements: [String: String],
        now: Date
    ) {
        guard status == .applied else { return }

        let effectiveFinal = finalText.isEmpty ? correctedText : finalText
        let existingReplacementKeys = Set(replacements.keys.map(Self.normalizedKey))
        let candidateTerms = Self.uniqueTerms(keyterms + Array(replacements.values) + Self.defaultCorrectionTargets)
        let lowerFinal = Self.normalizedText(effectiveFinal)
        let lowerCorrected = Self.normalizedText(correctedText)
        var seenSuggestionIDs = Set<String>()

        for candidate in Self.knownCorrectionCandidates {
            guard Self.containsTerm(candidate.from, in: observedRawText) else { continue }
            guard !existingReplacementKeys.contains(Self.normalizedKey(candidate.from)) else { continue }

            let target = candidate.targets.first { target in
                Self.containsTerm(target, in: effectiveFinal)
                    || Self.containsTerm(target, in: correctedText)
                    || candidateTerms.contains { Self.normalizedKey($0) == Self.normalizedKey(target) }
            }
            guard let target else { continue }
            guard lowerFinal.contains(Self.normalizedText(target)) || lowerCorrected.contains(Self.normalizedText(target)) else {
                continue
            }

            let suggestionID = Self.suggestionID(from: candidate.from, to: target)
            guard !seenSuggestionIDs.contains(suggestionID) else { continue }
            seenSuggestionIDs.insert(suggestionID)

            upsertSuggestion(from: candidate.from, to: target, confidence: candidate.confidence, now: now)
        }

        for target in candidateTerms where Self.isSafeCorrectionTarget(target) {
            guard
                lowerFinal.contains(Self.normalizedText(target)) || lowerCorrected.contains(Self.normalizedText(target)),
                !Self.containsTerm(target, in: observedRawText)
            else {
                continue
            }

            guard
                let source = Self.detectCorrectionSource(
                    for: target,
                    in: observedRawText,
                    existingReplacementKeys: existingReplacementKeys
                )
            else {
                continue
            }

            let suggestionID = Self.suggestionID(from: source, to: target)
            guard !seenSuggestionIDs.contains(suggestionID) else { continue }
            seenSuggestionIDs.insert(suggestionID)

            upsertSuggestion(from: source, to: target, confidence: 0.82, now: now)
        }
    }

    private func upsertSuggestion(from: String, to: String, confidence: Double, now: Date) {
        let id = Self.suggestionID(from: from, to: to)
        var suggestion =
            store.correctionSuggestions[id]
            ?? AIPolishCorrectionSuggestion(
                id: id,
                from: from,
                to: to,
                status: .pending,
                occurrences: 0,
                confidence: confidence,
                firstSeen: now,
                lastSeen: now
            )

        if suggestion.status == .rejected {
            suggestion.lastSeen = now
            store.correctionSuggestions[id] = suggestion
            return
        }

        suggestion.from = preferCorrectionSource(current: suggestion.from, candidate: from)
        suggestion.to = to
        suggestion.occurrences += 1
        suggestion.confidence = max(suggestion.confidence, confidence)
        suggestion.lastSeen = now
        store.correctionSuggestions[id] = suggestion
    }

    private func prune(now _: Date) {
        if store.correctionSuggestions.count > 250 {
            let keep = store.correctionSuggestions.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(250)
            store.correctionSuggestions = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
    }

    private func suggestions(status: AIPolishSuggestionStatus, limit: Int) -> [AIPolishCorrectionSuggestion] {
        store.correctionSuggestions.values
            .filter { $0.status == status }
            .sorted {
                if $0.occurrences == $1.occurrences {
                    return $0.lastSeen > $1.lastSeen
                }
                return $0.occurrences > $1.occurrences
            }
            .prefix(limit)
            .map { $0 }
    }

    private func publishSuggestions() {
        let pending = Self.visiblePendingSuggestions(from: store)
        let accepted = Self.visibleAcceptedSuggestions(from: store)
        if Thread.isMainThread {
            pendingSuggestions = pending
            acceptedSuggestions = accepted
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingSuggestions = pending
                self?.acceptedSuggestions = accepted
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder.prettyMemoryEncoder.encode(store) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func preferCorrectionSource(current: String, candidate: String) -> String {
        if current.contains(".") { return current }
        if candidate.contains(".") { return candidate }
        return current
    }

    private static func loadStore(from url: URL) -> Store {
        guard
            let data = try? Data(contentsOf: url),
            let store = try? JSONDecoder.memoryDecoder.decode(Store.self, from: data)
        else {
            return Store()
        }
        return store
    }

    private static func visiblePendingSuggestions(from store: Store) -> [AIPolishCorrectionSuggestion] {
        store.correctionSuggestions.values
            .filter { $0.status == .pending }
            .sorted {
                if $0.occurrences == $1.occurrences {
                    return $0.lastSeen > $1.lastSeen
                }
                return $0.occurrences > $1.occurrences
            }
            .prefix(8)
            .map { $0 }
    }

    private static func visibleAcceptedSuggestions(from store: Store) -> [AIPolishCorrectionSuggestion] {
        store.correctionSuggestions.values
            .filter { $0.status == .accepted }
            .sorted {
                if $0.occurrences == $1.occurrences {
                    return $0.lastSeen > $1.lastSeen
                }
                return $0.occurrences > $1.occurrences
            }
            .prefix(80)
            .map { $0 }
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedKey(trimmed)
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private static func isSafeCorrectionTarget(_ target: String) -> Bool {
        let alphanumericCount = target.filter { $0.isLetter || $0.isNumber }.count
        guard alphanumericCount >= 3 else { return false }

        let tokens = alphanumericTokens(in: target)
        if tokens.count > 1 { return true }
        if target.contains(where: { ".-_".contains($0) || $0.isNumber }) { return true }
        if target.contains(where: \.isUppercase) { return true }
        return target.count >= 8
    }

    private static func detectCorrectionSource(
        for target: String,
        in rawText: String,
        existingReplacementKeys: Set<String>
    ) -> String? {
        let targetKey = normalizedKey(target)

        for variant in correctionSourceVariants(for: target).sorted(by: { $0.count > $1.count }) {
            let sourceKey = normalizedKey(variant)
            guard
                sourceKey != targetKey,
                !isFragmentOfTarget(sourceKey: sourceKey, targetKey: targetKey),
                !existingReplacementKeys.contains(sourceKey),
                containsTerm(variant, in: rawText)
            else {
                continue
            }
            return variant
        }

        guard let fuzzy = bestFuzzySource(for: target, in: rawText) else { return nil }
        let sourceKey = normalizedKey(fuzzy)
        guard sourceKey != targetKey, !existingReplacementKeys.contains(sourceKey) else { return nil }
        return fuzzy
    }

    /// A legitimate correction source is a DISTORTION of the target ("kit
    /// push", "cloud code"), never a correctly-spelled fragment of it ("push",
    /// "Code"). Fragment mappings applied as whole-word replacements would
    /// rewrite normal prose — every plain "push" becoming "git push" — so they
    /// are rejected before ever reaching the suggestions UI.
    private static func isFragmentOfTarget(sourceKey: String, targetKey: String) -> Bool {
        !sourceKey.isEmpty && targetKey.contains(sourceKey)
    }

    private static func correctionSourceVariants(for target: String) -> [String] {
        var forms: [String] = []
        forms.append(spokenForm(for: target))
        forms.append(spokenSymbolForm(for: target, symbolWord: "dot"))
        forms.append(spokenSymbolForm(for: target, symbolWord: "period"))
        forms.append(spokenSymbolForm(for: target, symbolWord: "punto"))
        if !target.hasPrefix(".") {
            forms.append(condensedSymbolForm(for: target))
        }

        appendReplacementVariants(
            for: target,
            replacing: "Claude",
            with: ["Cloud", "Claw", "Clawd", "Clawed", "Claud", "Clauco", "Clouco", "Slough", "Clog"],
            to: &forms
        )
        appendReplacementVariants(
            for: target,
            replacing: "Deepgram",
            with: ["Deep gram", "Depgram", "Deppgram", "Ditgram"],
            to: &forms
        )
        appendReplacementVariants(
            for: target,
            replacing: "ElevenLabs",
            with: ["Eleven Labs", "11labs"],
            to: &forms
        )
        appendReplacementVariants(
            for: target,
            replacing: "Local AI Server",
            with: ["localize server", "local ya server", "localia server"],
            to: &forms
        )
        appendReplacementVariants(
            for: target,
            replacing: "SapoWhisper",
            with: ["Sapo Whisper", "Sapo Visper", "Sapa Whisper", "Zapo Whisper", "Sapowisper"],
            to: &forms
        )

        switch normalizedKey(target) {
        case "claude md":
            forms.append(contentsOf: ["cloud md", "cloud dot md", "claude dot md", "claud mendy", "claude mendy"])
        case "agents md":
            forms.append(contentsOf: ["legends.md", "legends md", "legends dot md", "legends punto md", "nats md"])
        case "git commit":
            forms.append(contentsOf: ["deep commit", "deep comment", "deep comet", "dip comment", "kit commit"])
        case "git push":
            forms.append(contentsOf: ["deep push", "dip push", "kit push", "hit pug"])
        case "rest api", "api rest":
            forms.append(contentsOf: ["ali test", "restapi"])
        case "pull request":
            forms.append("pool request")
        default:
            break
        }

        return uniqueTerms(forms).filter { normalizedKey($0) != normalizedKey(target) }
    }

    private static func bestFuzzySource(for target: String, in rawText: String) -> String? {
        let targetTokens = alphanumericTokens(in: target)
        guard !targetTokens.isEmpty else { return nil }

        let rawWords = wordRuns(in: rawText)
        guard !rawWords.isEmpty else { return nil }

        var best: (phrase: String, score: Double)?
        let maxWindow = min(max(targetTokens.count + 1, 1), 4)
        for size in 1...maxWindow where rawWords.count >= size {
            for index in 0...(rawWords.count - size) {
                let phrase = rawWords[index..<(index + size)].joined(separator: " ")
                let sourceKey = normalizedKey(phrase)
                guard
                    sourceKey.count >= 4,
                    !sourceKey.contains(normalizedKey(target)),
                    !isFragmentOfTarget(sourceKey: sourceKey, targetKey: normalizedKey(target)),
                    !commonCorrectionSourceWords.contains(sourceKey)
                else {
                    continue
                }

                let score = fuzzyScore(sourceKey: sourceKey, targetTokens: targetTokens, targetKey: normalizedKey(target))
                guard score >= 0.84 else { continue }
                if best.map({ score > $0.score }) ?? true {
                    best = (phrase, score)
                }
            }
        }

        return best?.phrase
    }

    private static func fuzzyScore(sourceKey: String, targetTokens: [String], targetKey: String) -> Double {
        let tokenScores = targetTokens.map { similarity(sourceKey, normalizedKey($0)) }
        return max(similarity(sourceKey, targetKey), tokenScores.max() ?? 0)
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let distance = editDistance(Array(lhs), Array(rhs))
        return 1 - (Double(distance) / Double(max(lhs.count, rhs.count)))
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current[rightIndex + 1] = min(substitution, insertion, deletion)
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func wordRuns(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}._-]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func containsTerm(_ term: String, in text: String) -> Bool {
        let normalizedTerm = normalizedText(term)
        guard !normalizedTerm.isEmpty else { return false }
        return normalizedText(text).contains(normalizedTerm)
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s._,-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedKey(_ text: String) -> String {
        normalizedText(text).lowercased()
    }

    private static func spokenForm(for term: String) -> String {
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

    private static func spokenSymbolForm(for term: String, symbolWord: String) -> String {
        term
            .replacingOccurrences(of: ".", with: " \(symbolWord) ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func condensedSymbolForm(for term: String) -> String {
        term.replacingOccurrences(of: #"[-_.\s]+"#, with: "", options: .regularExpression)
    }

    private static func appendReplacementVariants(
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

    private static func alphanumericTokens(in term: String) -> [String] {
        term.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func shouldInsertSpeechSpace(previous: Character, current: Character, next: Character?) -> Bool {
        guard current.isUppercase else { return false }
        if previous.isLowercase || previous.isNumber { return true }
        if previous.isUppercase, next?.isLowercase == true { return true }
        return false
    }

    private static func suggestionID(from: String, to: String) -> String {
        "\(normalizedKey(from))->\(normalizedKey(to))"
    }

    private static let commonCorrectionSourceWords: Set<String> = [
        "ahora",
        "antes",
        "como",
        "cuando",
        "donde",
        "entonces",
        "esto",
        "este",
        "esta",
        "para",
        "pero",
        "porque",
        "solo",
        "solamente",
        "tambien",
        "también",
        "that",
        "there",
        "this",
        "with",
    ]

    private static let defaultCorrectionTargets = [
        "AI polish",
        "AGENTS.md",
        "API REST",
        "CLAUDE.md",
        "Claude Code",
        "Deepgram",
        "Local AI Server",
        "REST API",
        "git commit",
        "git push",
        "pull request",
    ]

    private static let knownCorrectionCandidates: [CorrectionCandidate] = [
        CorrectionCandidate(from: "deep commit", targets: ["git commit"], confidence: 0.96),
        CorrectionCandidate(from: "deep comment", targets: ["git commit"], confidence: 0.96),
        CorrectionCandidate(from: "deep comet", targets: ["git commit"], confidence: 0.94),
        CorrectionCandidate(from: "dip comment", targets: ["git commit"], confidence: 0.92),
        CorrectionCandidate(from: "deep push", targets: ["git push"], confidence: 0.94),
        CorrectionCandidate(from: "dip push", targets: ["git push"], confidence: 0.92),
        CorrectionCandidate(from: "legends.md", targets: ["AGENTS.md"], confidence: 0.9),
        CorrectionCandidate(from: "legends md", targets: ["AGENTS.md"], confidence: 0.9),
        CorrectionCandidate(from: "legends dot md", targets: ["AGENTS.md"], confidence: 0.88),
        CorrectionCandidate(from: "legends punto md", targets: ["AGENTS.md"], confidence: 0.88),
        CorrectionCandidate(from: "cloud md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.94),
        CorrectionCandidate(from: "cloud dot md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.92),
        CorrectionCandidate(from: "claude dot md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.92),
        CorrectionCandidate(from: "clauco", targets: ["Claude Code", "CLAUDE.md", "Claude"], confidence: 0.88),
        CorrectionCandidate(from: "cloud code", targets: ["Claude Code"], confidence: 0.91),
        CorrectionCandidate(from: "claud code", targets: ["Claude Code"], confidence: 0.91),
        CorrectionCandidate(from: "ditgram", targets: ["Deepgram"], confidence: 0.88),
        CorrectionCandidate(from: "ali test", targets: ["REST API", "API REST"], confidence: 0.9),
        CorrectionCandidate(from: "api rest", targets: ["REST API", "API REST"], confidence: 0.88),
        CorrectionCandidate(from: "restapi", targets: ["REST API"], confidence: 0.88),
        CorrectionCandidate(from: "local ya server", targets: ["Local AI Server"], confidence: 0.9),
        CorrectionCandidate(from: "localia server", targets: ["Local AI Server"], confidence: 0.9),
        CorrectionCandidate(from: "pool request", targets: ["pull request"], confidence: 0.9),
    ]

    private struct Store: Codable {
        var version = 2
        var totalTranscripts = 0
        var lastUpdated: Date?
        var correctionSuggestions: [String: AIPolishCorrectionSuggestion] = [:]
    }

    private struct CorrectionCandidate {
        let from: String
        let targets: [String]
        let confidence: Double
    }
}

extension JSONEncoder {
    fileprivate static var prettyMemoryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var memoryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
