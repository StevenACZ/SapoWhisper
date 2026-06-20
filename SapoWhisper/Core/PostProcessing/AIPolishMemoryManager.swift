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
    let topDailyTerms: [String]
    let topWeeklyTerms: [String]
    let acceptedCorrections: [AIPolishCorrectionSuggestion]
    let pendingCorrections: [AIPolishCorrectionSuggestion]

    var promptBlock: String {
        var lines: [String] = [
            "<local_learning_memory>",
            "Detected writing mode: \(detectedMode.promptName)",
        ]

        lines.append("Top terms today: \(topDailyTerms.isEmpty ? "none" : topDailyTerms.joined(separator: ", "))")
        lines.append("Top terms this week: \(topWeeklyTerms.isEmpty ? "none" : topWeeklyTerms.joined(separator: ", "))")

        let accepted = acceptedCorrections.map { "\"\(sanitize($0.from))\" -> \"\(sanitize($0.to))\"" }
        lines.append("Accepted corrections: \(accepted.isEmpty ? "none" : accepted.joined(separator: "; "))")

        let pending = pendingCorrections.map { "\"\(sanitize($0.from))\" -> \"\(sanitize($0.to))\"" }
        lines.append("Candidate corrections: \(pending.isEmpty ? "none" : pending.joined(separator: "; "))")

        lines.append(
            "For accepted and candidate corrections, the right side is the canonical wording. If the transcript contains the left side in the same domain, replace that phrase with the right side."
        )
        lines.append(
            "Use this local memory only as recognition context. "
                + "Never inject a term when the transcript does not clearly point to it."
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
    private var calendar: Calendar

    init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
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
        let today = dayKey(for: now)
        let week = weekKey(for: now)

        return AIPolishMemoryContext(
            detectedMode: detectedMode,
            topDailyTerms: topTerms(for: today, keyPath: \.dayCounts, limit: 12),
            topWeeklyTerms: topTerms(for: week, keyPath: \.weekCounts, limit: 16),
            acceptedCorrections: suggestions(status: .accepted, limit: 12),
            pendingCorrections: suggestions(status: .pending, limit: 8)
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

        recordTerms(in: final.isEmpty ? corrected : final, keyterms: keyterms, replacements: replacements, now: now)
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

    func snapshot() -> (terms: [TermUsageRecord], suggestions: [AIPolishCorrectionSuggestion]) {
        lock.lock()
        defer { lock.unlock() }
        return (
            terms: store.termStats.values.sorted { $0.totalCount > $1.totalCount },
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

    private func recordTerms(
        in text: String,
        keyterms: [String],
        replacements: [String: String],
        now: Date
    ) {
        let knownTerms = Self.uniqueTerms(keyterms + Array(replacements.values))
        let knownMatches = knownTerms.filter { Self.containsTerm($0, in: text) }
        let inferredTerms = Self.inferredTerms(from: text)
        let terms = Self.uniqueTerms(knownMatches + inferredTerms).prefix(40)
        let today = dayKey(for: now)
        let week = weekKey(for: now)

        for term in terms {
            let normalized = Self.normalizedKey(term)
            guard !normalized.isEmpty else { continue }

            var record = store.termStats[normalized] ?? TermUsageRecord(term: term)
            record.term = preferDisplayTerm(current: record.term, candidate: term)
            record.totalCount += 1
            record.dayCounts[today, default: 0] += 1
            record.weekCounts[week, default: 0] += 1
            record.lastSeen = now
            store.termStats[normalized] = record
        }
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

        suggestion.from = from
        suggestion.to = to
        suggestion.occurrences += 1
        suggestion.confidence = max(suggestion.confidence, confidence)
        suggestion.lastSeen = now
        store.correctionSuggestions[id] = suggestion
    }

    private func prune(now: Date) {
        let cutoff = calendar.date(byAdding: .day, value: -60, to: now) ?? now

        store.termStats = store.termStats.filter { _, record in
            record.lastSeen >= cutoff
        }
        for (key, var record) in store.termStats {
            record.dayCounts = record.dayCounts.filter { $0.key >= dayKey(for: cutoff) }
            record.weekCounts = record.weekCounts.filter { $0.key >= weekKey(for: cutoff) }
            store.termStats[key] = record
        }

        if store.correctionSuggestions.count > 250 {
            let keep = store.correctionSuggestions.values
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(250)
            store.correctionSuggestions = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
    }

    private func topTerms(
        for key: String,
        keyPath: KeyPath<TermUsageRecord, [String: Int]>,
        limit: Int
    ) -> [String] {
        store.termStats.values
            .compactMap { record -> (String, Int)? in
                guard let count = record[keyPath: keyPath][key], count > 0 else { return nil }
                return (record.term, count)
            }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.localizedStandardCompare($1.0) == .orderedAscending
                }
                return $0.1 > $1.1
            }
            .prefix(limit)
            .map(\.0)
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

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func weekKey(for date: Date) -> String {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    private func preferDisplayTerm(current: String, candidate: String) -> String {
        if current == current.lowercased(), candidate != candidate.lowercased() {
            return candidate
        }
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

    private static func inferredTerms(from text: String) -> [String] {
        let patterns = [
            #"\b[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+\b"#,
            #"(?<![A-Za-z0-9])\.[A-Za-z0-9_-]+\b"#,
            #"\b[A-Z]{2,}(?:\s+[A-Z]{2,})?\b"#,
            #"\b(?:git|npm|pnpm|swift|xcodebuild|make|curl|docker|kubectl|ssh|scp|rsync)\s+[A-Za-z0-9_./:-]+(?:\s+[A-Za-z0-9_./:=@-]+)?"#,
        ]

        let rawTerms = patterns.flatMap { pattern in
            matches(pattern: pattern, in: text)
        }
        let richerTermKeys = Set(
            rawTerms
                .filter { $0.contains(".") || $0.contains("-") || $0.contains("/") }
                .flatMap { alphanumericTokens(in: $0).map { $0.lowercased() } }
        )
        let stopTerms: Set<String> = ["ai", "ia", "ok"]
        let standaloneExtensionNoise: Set<String> = [
            ".css", ".csv", ".html", ".js", ".json", ".jsx", ".md", ".mp3", ".mp4", ".py", ".sql",
            ".swift", ".ts", ".tsx", ".txt", ".wav", ".yaml", ".yml",
        ]
        let allowedAcronyms: Set<String> = [
            "api", "api rest", "ci", "cli", "http", "https", "json", "llm", "pr", "rest api", "sql", "stt",
            "tts", "url", "uuid", "vps",
        ]
        let commandFollowerNoise: Set<String> = [
            "a", "al", "con", "de", "del", "el", "en", "es", "la", "las", "lo", "los", "para", "por", "que",
            "sin", "un", "una", "y",
        ]

        return rawTerms.filter { term in
            let normalized = normalizedKey(term)
            guard !stopTerms.contains(normalized) else { return false }
            guard !standaloneExtensionNoise.contains(term.lowercased()) else { return false }
            if let firstSpace = normalized.firstIndex(of: " ") {
                let command = String(normalized[..<firstSpace])
                let follower = String(normalized[normalized.index(after: firstSpace)...])
                if ["git", "npm", "pnpm", "swift", "xcodebuild", "make", "curl", "docker", "kubectl", "ssh", "scp", "rsync"]
                    .contains(command),
                    commandFollowerNoise.contains(follower)
                {
                    return false
                }
            }
            guard !(term == term.uppercased() && term.count > 3 && richerTermKeys.contains(normalized)) else {
                return false
            }
            guard
                !(term == term.uppercased() && !term.contains(where: { ".-/".contains($0) })
                    && !allowedAcronyms.contains(normalized))
            else {
                return false
            }
            return true
        }
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range, in: text) else { return nil }
            return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    private static func alphanumericTokens(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
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

    struct TermUsageRecord: Codable, Equatable {
        var term: String
        var totalCount: Int
        var dayCounts: [String: Int]
        var weekCounts: [String: Int]
        var lastSeen: Date

        init(term: String) {
            self.term = term
            self.totalCount = 0
            self.dayCounts = [:]
            self.weekCounts = [:]
            self.lastSeen = Date(timeIntervalSince1970: 0)
        }
    }

    private struct Store: Codable {
        var version = 1
        var totalTranscripts = 0
        var lastUpdated: Date?
        var modeCounts: [String: Int] = [:]
        var termStats: [String: TermUsageRecord] = [:]
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
