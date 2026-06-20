//
//  AIPolishMemoryManager.swift
//  SapoWhisper
//

import Combine
import Foundation

enum AIPolishDetectedMode: String, Codable, Equatable {
    case technical
    case work
    case finance
    case natural

    var promptName: String {
        switch self {
        case .technical:
            return "technical"
        case .work:
            return "work"
        case .finance:
            return "finance"
        case .natural:
            return "natural"
        }
    }
}

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

struct AIPolishMemoryContext: Equatable {
    let detectedMode: AIPolishDetectedMode
    let acceptedCorrections: [AIPolishCorrectionSuggestion]

    var promptBlock: String {
        var lines: [String] = [
            "<local_learning_memory>",
            "Detected writing mode: \(detectedMode.promptName)",
        ]

        let accepted = acceptedCorrections.map { "\"\(sanitize($0.from))\" -> \"\(sanitize($0.to))\"" }
        lines.append("Accepted corrections: \(accepted.isEmpty ? "none" : accepted.joined(separator: "; "))")

        lines.append(
            "For accepted corrections, the right side is the canonical wording. If the transcript contains the left side in the same domain, replace that phrase with the right side."
        )
        lines.append(
            "Use this local memory only as correction context. Never create or recommend vocabulary/keyterms. Never inject a term when the transcript does not clearly point to it."
        )
        lines.append(
            "Mode guidance: technical keeps commands/files/APIs exact; work uses readable message punctuation; finance preserves amounts, dates, tickers, and entities; natural keeps a conversational tone."
        )
        lines.append("</local_learning_memory>")
        return lines.joined(separator: "\n")
    }

    private func sanitize(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AIPolishMemoryManager: ObservableObject {
    static let shared = AIPolishMemoryManager()

    @Published private(set) var pendingSuggestions: [AIPolishCorrectionSuggestion] = []

    private let fileURL: URL
    private let lock = NSRecursiveLock()
    private var store: Store

    init(fileURL: URL, calendar _: Calendar = .current) {
        self.fileURL = fileURL
        self.store = Self.loadStore(from: fileURL)
        self.pendingSuggestions = Self.visiblePendingSuggestions(from: store)
    }

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.init(fileURL: appDir.appendingPathComponent("ai-polish-memory.json"))
    }

    func contextPacket(
        rawText: String,
        correctedText: String,
        keyterms: [String],
        replacements: [String: String],
        now: Date = Date()
    ) -> AIPolishMemoryContext {
        lock.lock()
        defer { lock.unlock() }

        let detectedMode = Self.detectedMode(
            in: [rawText, correctedText, keyterms.joined(separator: " "), replacements.values.joined(separator: " ")]
                .joined(separator: " ")
        )

        return AIPolishMemoryContext(
            detectedMode: detectedMode,
            acceptedCorrections: suggestions(status: .accepted, limit: 12)
        )
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
        store.modeCounts[Self.detectedMode(in: [raw, corrected, final].joined(separator: " ")).rawValue, default: 0] += 1

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
        publishPendingSuggestions()
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
        publishPendingSuggestions()
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
        publishPendingSuggestions()
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
            guard status == .applied || correctedText != observedRawText else { continue }

            let suggestionID = Self.suggestionID(from: candidate.from, to: target)
            guard !seenSuggestionIDs.contains(suggestionID) else { continue }
            seenSuggestionIDs.insert(suggestionID)

            upsertSuggestion(from: candidate.from, to: target, confidence: candidate.confidence, now: now)
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

    private func publishPendingSuggestions() {
        let suggestions = Self.visiblePendingSuggestions(from: store)
        if Thread.isMainThread {
            pendingSuggestions = suggestions
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pendingSuggestions = suggestions
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

    private static func detectedMode(in text: String) -> AIPolishDetectedMode {
        let lower = text.lowercased()
        if containsAny(
            lower,
            [
                "git", "commit", "pull request", "api", "rest", "claude", "agents.md", "readme", "xcodebuild",
                "swift", "npm", "pnpm", "docker", "kubernetes", "ssh", "json", ".env", ".gitignore",
            ]
        ) {
            return .technical
        }
        if containsAny(
            lower,
            [
                "acciones", "inversion", "inversión", "portfolio", "dividendo", "ticker", "factura", "presupuesto",
                "cotizacion", "cotización", "impuesto", "revenue", "margin",
            ]
        ) {
            return .finance
        }
        if containsAny(
            lower,
            [
                "reunion", "reunión", "cliente", "slack", "correo", "email", "agenda", "equipo", "entrega",
                "deadline", "prioridad",
            ]
        ) {
            return .work
        }
        return .natural
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
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

    private static func suggestionID(from: String, to: String) -> String {
        "\(normalizedKey(from))->\(normalizedKey(to))"
    }

    private static let defaultCorrectionTargets = [
        "AI polish",
        "AGENTS.md",
        "API REST",
        "CLAUDE.md",
        "Claude Code",
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
        CorrectionCandidate(from: "legends.md", targets: ["AGENTS.md"], confidence: 0.9),
        CorrectionCandidate(from: "legends md", targets: ["AGENTS.md"], confidence: 0.9),
        CorrectionCandidate(from: "legends dot md", targets: ["AGENTS.md"], confidence: 0.88),
        CorrectionCandidate(from: "legends punto md", targets: ["AGENTS.md"], confidence: 0.88),
        CorrectionCandidate(from: "cloud md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.94),
        CorrectionCandidate(from: "cloud dot md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.92),
        CorrectionCandidate(from: "claude dot md", targets: ["CLAUDE.md", "Claude.md"], confidence: 0.92),
        CorrectionCandidate(from: "cloud code", targets: ["Claude Code"], confidence: 0.91),
        CorrectionCandidate(from: "claud code", targets: ["Claude Code"], confidence: 0.91),
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
        var modeCounts: [String: Int] = [:]
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
