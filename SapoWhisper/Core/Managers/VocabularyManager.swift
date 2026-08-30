//
//  VocabularyManager.swift
//  SapoWhisper
//

import Foundation
import Observation

/// ElevenLabs keyterm biasing limits, shared by the request builders and the
/// vocabulary UI so over-limit terms are surfaced instead of silently dropped.
enum ElevenLabsKeytermLimits {
    static let batchMaxCount = 1000
    static let batchMaxLength = 50
    static let batchMaxWords = 5
    static let realtimeMaxCount = 50
    static let realtimeMaxLength = 20
}

enum DeepgramKeytermLimits {
    static let maxCount = 1000
    static let maxLength = 100
    static let maxTotalWords = 80
}

/// Manages keyterms and replacements for speech recognition engines.
/// Persists to ~/Library/Application Support/SapoWhisper/vocabulary.json
@Observable
class VocabularyManager {

    static let shared = VocabularyManager()

    private(set) var keyterms: [String] = []
    private(set) var replacements: [String: String] = [:]
    private(set) var includeReplacementTargetsInRecognitionHints = true

    private let fileURL: URL

    /// Designated init. Tests inject a temp file URL so they never touch the
    /// user's vocabulary.json; production uses the app-support path below.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.init(fileURL: appDir.appendingPathComponent("vocabulary.json"))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        keyterms = (json["keyterms"] as? [String]) ?? []
        replacements = (json["replacements"] as? [String: String]) ?? [:]
        includeReplacementTargetsInRecognitionHints =
            (json["includeReplacementTargetsInRecognitionHints"] as? Bool) ?? true
    }

    private func save() {
        let json: [String: Any] = [
            "includeReplacementTargetsInRecognitionHints": includeReplacementTargetsInRecognitionHints,
            "keyterms": keyterms,
            "replacements": replacements,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) else { return }
        // Atomic write: a crash mid-write must not truncate/corrupt vocabulary.json.
        try? data.write(to: fileURL, options: .atomic)
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

    func setIncludeReplacementTargetsInRecognitionHints(_ enabled: Bool) {
        includeReplacementTargetsInRecognitionHints = enabled
        save()
    }

    // MARK: - Import / Export

    func snapshot() -> VocabularySnapshot {
        VocabularySnapshot(
            keyterms: keyterms,
            replacements: replacements,
            includeReplacementTargetsInRecognitionHints: includeReplacementTargetsInRecognitionHints
        )
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

        if let includeReplacementTargets = snapshot.includeReplacementTargetsInRecognitionHints {
            includeReplacementTargetsInRecognitionHints = includeReplacementTargets
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
        let payload = recognitionKeytermPayload(
            maxCount: DeepgramKeytermLimits.maxCount,
            maxLength: DeepgramKeytermLimits.maxLength
        )
        var totalWords = 0
        return payload.terms.compactMap { term in
            let words = max(1, term.split(separator: " ").count)
            guard totalWords + words <= DeepgramKeytermLimits.maxTotalWords else {
                return nil
            }
            totalWords += words
            return URLQueryItem(name: "keyterm", value: term)
        }
    }

    /// Returns replace query items for Deepgram batch REST requests
    func replaceQueryItems() -> [URLQueryItem] {
        mechanicalReplacements.map { URLQueryItem(name: "replace", value: "\($0.key):\($0.value)") }
    }

    /// Replacement pairs safe for mechanical passes (the local regex pass and
    /// Deepgram's server-side `replace`): re-applying the pair to its own
    /// value must be a no-op. An expansion pair like "push" -> "git push"
    /// fails that check — mechanically it turns an already-correct "git push"
    /// into "git git push" — so only the AI polish dictionary (which reads
    /// context) sees those pairs.
    var mechanicalReplacements: [String: String] {
        replacements.filter { Self.isMechanicallyStable(key: $0.key, value: $0.value) }
    }

    private static func isMechanicallyStable(key: String, value: String) -> Bool {
        let pattern = replacementPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let template = NSRegularExpression.escapedTemplate(for: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template) == value
    }

    /// Applies saved replacements locally for engines that do not expose replace in their API surface.
    func applyingReplacements(to transcript: String) -> String {
        mechanicalReplacements
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

    /// Returns keyterms shaped for engines that accept server-side recognition
    /// hints. CANONICAL forms only — the same rule the Whisper initial prompt
    /// follows: sending misheard variants ("Clauco", "hit pug") as hints
    /// actively biases the engine toward the wrong spelling and burns the
    /// provider's term budget (Deepgram caps at 100 terms; ElevenLabs bills a
    /// 20s minimum past 100). Variants are recovered after the fact by the
    /// deterministic correction pass and the AI polish prompt.
    func recognitionKeytermPayload(
        maxCount: Int,
        maxLength: Int,
        maxWords: Int? = nil,
        includeReplacementValues: Bool? = nil
    ) -> (terms: [String], droppedCount: Int) {
        let candidates = recognitionCandidates(
            includeReplacementValues: includeReplacementValues
                ?? includeReplacementTargetsInRecognitionHints
        )
        var seen = Set<String>()
        var canonicalTerms: [String] = []

        for candidate in candidates {
            let trimmed = Self.sanitizedRecognitionHint(candidate)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            canonicalTerms.append(trimmed)
        }

        let validTerms = canonicalTerms.filter { term in
            term.count <= maxLength && (maxWords.map { term.split(separator: " ").count <= $0 } ?? true)
        }
        let terms = Array(validTerms.prefix(maxCount))
        return (terms, max(0, canonicalTerms.count - terms.count))
    }

    /// Whisper-style initial prompt for local STT engines (MLX Whisper and the
    /// Local AI Server). Unlike the cloud keyterm payloads, this shows the
    /// decoder only the CANONICAL spellings — feeding misheard variants here
    /// would teach the model the wrong forms. Whisper conditions on roughly the
    /// last 224 tokens, so the glossary is capped and keeps the user's own
    /// keyterms first (they outrank replacement values on overflow).
    func initialPromptText(maxLength: Int = 700) -> String {
        let terms = echoDetectionTerms()
        guard !terms.isEmpty else { return "" }

        let prefix = "Glossary: "
        var body = ""
        for term in terms {
            let candidate = body.isEmpty ? term : "\(body), \(term)"
            guard prefix.count + candidate.count + 1 <= maxLength else { break }
            body = candidate
        }
        guard !body.isEmpty else { return "" }
        return "\(prefix)\(body)."
    }

    /// Canonical vocabulary terms as the initial prompt sees them.
    func echoDetectionTerms() -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for candidate in recognitionCandidates(
            includeReplacementValues: includeReplacementTargetsInRecognitionHints
        ) {
            let sanitized = Self.sanitizedRecognitionHint(candidate)
            let key = sanitized.lowercased()
            guard !sanitized.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            terms.append(sanitized)
        }
        return terms
    }

    /// Applies saved replacements and high-confidence vocabulary spelling corrections.
    func applyingRecognitionCorrections(to transcript: String) -> String {
        let replacedTranscript = applyingReplacements(to: transcript)
        let candidates = recognitionCandidates(includeReplacementValues: true)
        let canonicalKeys = Set(candidates.map(Self.normalizedRecognitionKey))
        let correctionPairs =
            candidates
            .flatMap { keyterm in
                Self.correctionVariants(for: keyterm).map { variant in
                    (variant: variant, canonical: keyterm)
                }
            }
            .filter { pair in
                let variantKey = Self.normalizedRecognitionKey(pair.variant)
                let canonicalKey = Self.normalizedRecognitionKey(pair.canonical)
                return variantKey == canonicalKey || !canonicalKeys.contains(variantKey)
            }
            .sorted { $0.variant.count > $1.variant.count }

        let phraseCorrectedTranscript = applyingMultiTermCorrections(to: replacedTranscript)
        return correctionPairs.reduce(phraseCorrectedTranscript) { current, pair in
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

    private func applyingMultiTermCorrections(to transcript: String) -> String {
        let availableTerms = Set(
            recognitionCandidates(includeReplacementValues: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        var current = transcript
        let knowsGitCommit =
            availableTerms.contains("git commit")
            || (availableTerms.contains("git") && availableTerms.contains("commit"))
        let knowsGitPush =
            availableTerms.contains("git push")
            || (availableTerms.contains("git") && availableTerms.contains("push"))
        if knowsGitCommit {
            current = Self.replacingWholeTermVariants(
                [
                    "deep comment", "deep comet", "dip comment", "hit commit", "hiit commit",
                    "heat commit", "hit con meat", "hiit con meat", "heat con meat",
                ],
                with: "git commit",
                in: current
            )
        }
        if knowsGitPush {
            current = Self.replacingWholeTermVariants(
                ["deep push", "dip push", "hit push", "hiit push", "heat push"],
                with: "git push",
                in: current
            )
        }
        if availableTerms.contains("git") || knowsGitCommit {
            current = Self.replacingWholeTermVariants(
                ["KitCom", "KitComit", "KitCommit", "Kit Commit"],
                with: "git commit",
                in: current
            )
        }
        if availableTerms.contains("git") || knowsGitPush {
            current = Self.replacingWholeTermVariants(["KitPush", "Kit Push"], with: "git push", in: current)
        }
        return current
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
        let baseVariants =
            keyterm.hasPrefix(".")
            ? [
                keyterm,
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "dot"),
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "period"),
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "punto"),
            ]
            : [
                keyterm,
                SpeechConfusionCatalog.spokenForm(for: keyterm),
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "dot"),
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "period"),
                SpeechConfusionCatalog.spokenSymbolForm(for: keyterm, symbolWord: "punto"),
            ]
        let spokenVariants = baseVariants + speechConfusionForms(for: keyterm)

        let condensedVariants =
            keyterm.hasPrefix(".") ? [] : spokenVariants.map(SpeechConfusionCatalog.condensedSymbolForm)
        return uniqueVariants(spokenVariants + condensedVariants)
    }

    /// Single-word variants that are also everyday words. Applied
    /// deterministically they rewrite legitimate speech ("a hit on Spotify" →
    /// "a git on Spotify", "mi perro pug" → "mi perro push"), so they never
    /// join the mechanical correction pass — the AI polish prompt still sees
    /// them, where context judgment exists. Multi-word forms ("hit pug",
    /// "deep comment") stay mechanical: the bigram is specific enough.
    private static let contextOnlyCorrectionVariants: Set<String> = [
        "hit", "pug", "comet", "cloud", "claw", "clawed", "clog", "slough",
    ]

    private static func correctionVariants(for keyterm: String) -> [String] {
        recognitionVariants(for: keyterm).filter {
            !contextOnlyCorrectionVariants.contains($0.lowercased())
        }
    }

    private static func replacingWholeTermVariants(_ variants: [String], with canonical: String, in transcript: String)
        -> String
    {
        variants.reduce(transcript) { current, variant in
            let pattern = wholeTermPattern(for: variant)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return current
            }
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            let replacementTemplate = NSRegularExpression.escapedTemplate(for: canonical)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: replacementTemplate
            )
        }
    }

    private static func replacementPattern(for term: String) -> String {
        guard term.contains(where: { ".-_".contains($0) }) else {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return "\\b\(escaped)\\b"
        }

        let body = term.map { character -> String in
            switch character {
            case ".":
                return #"(?:\s*(?:\.|dot|period|punto)?\s*)"#
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

    private static func speechConfusionForms(for keyterm: String) -> [String] {
        var forms: [String] = []

        SpeechConfusionCatalog.appendBrandVariants(for: keyterm, to: &forms)
        if keyterm.lowercased() == "claude.md" {
            forms.append(contentsOf: ["claud mendy", "claude mendy", "cod md"])
        }
        if keyterm.lowercased() == ".env" {
            forms.append(
                contentsOf: [
                    ".em",
                    ".emb",
                    ".m",
                    "dot em",
                    "dot emb",
                    "dot m",
                    "period m",
                    "punto em",
                    "punto emb",
                    "punto m",
                    "punto env",
                ]
            )
        }
        if keyterm.lowercased() == ".gitignore" {
            forms.append(contentsOf: ["punto git ignore", "punto geek ignore", "punto kid ignore"])
        }
        if keyterm.lowercased() == "agents.md" {
            forms.append(
                contentsOf: [
                    "agens md",
                    "agents knotsmd",
                    "legends md",
                    "legends dot md",
                    "legends punto md",
                    "legends.md",
                    "nats md",
                    "agients md",
                    "ages md",
                    "ages punto md",
                    "ages punto m d",
                    "agents punto md",
                    "agents punto m d",
                ]
            )
        }
        if keyterm.lowercased() == "app store connect" {
            forms.append(contentsOf: ["AppStore Connect", "AppStore, Connect", "Store Connect"])
        }
        if keyterm.lowercased() == "nova-3" {
            forms.append(contentsOf: ["Nova three", "Nova tres"])
        }
        if keyterm.lowercased() == "scribe v2" {
            forms.append(
                contentsOf: [
                    "Scribe v two",
                    "Scribe version 2",
                    "Scribe version dos",
                    "Scribe versión 2",
                    "Scribe versión dos",
                    "Scri Scribe version dos",
                    "Scri Scribe versión dos",
                ]
            )
        }
        let lowercasedKeyterm = keyterm.lowercased()
        if lowercasedKeyterm == "local ai server (nvidia)" {
            forms.append(contentsOf: [
                "Local AI Server NVIDIA", "Local AI Server, NVIDIA", "local ya server NVIDIA", "localia server NVIDIA",
            ])
        }
        if lowercasedKeyterm == "ai polish" {
            forms.append(contentsOf: ["a AI", "a AI polish", "ahí a Polish"])
        }
        if lowercasedKeyterm == "commit" {
            forms.append(contentsOf: ["comet", "comit", "commet", "HacerunComet"])
        }
        if lowercasedKeyterm == "git commit" {
            forms.append(
                contentsOf: [
                    "deep comment", "deep comet", "dip comment", "hago Kimi", "Kit commit", "KitCom",
                    "KitComit", "KitCommit",
                ])
        }
        if lowercasedKeyterm == "kimi v2" {
            forms.append(
                contentsOf: [
                    "KimiV2",
                    "Kimi P2",
                    "Kimi P 2",
                    "KimiVersión2",
                    "Kimi version 2",
                    "Kimi version dos",
                    "Kimi versión dos",
                    "Kimi V two",
                    "Kimi V dos",
                ]
            )
        }
        if lowercasedKeyterm == "qbitorrent" || lowercasedKeyterm == "qbittorrent" {
            forms.append(contentsOf: [
                "KubiTorret", "Kubi Torrent", "QubiTorrent", "Qubitorrel", "Cubitorrel", "qBittorrent", "qbittorrent",
            ])
        }
        if lowercasedKeyterm == "vue 3" {
            forms.append("Vue three")
        }
        if lowercasedKeyterm == "git" || lowercasedKeyterm.hasPrefix("git ") {
            SpeechConfusionCatalog.appendReplacementVariants(
                for: keyterm,
                replacing: "git",
                with: ["hit"],
                to: &forms
            )
        }
        if lowercasedKeyterm == "push" || lowercasedKeyterm.contains(" push") {
            SpeechConfusionCatalog.appendReplacementVariants(
                for: keyterm,
                replacing: "push",
                with: ["pug"],
                to: &forms
            )
        }
        if lowercasedKeyterm == "git push" {
            forms.append(contentsOf: ["deep push", "dip push", "hit pug", "kit push", "KitPush"])
        }
        if lowercasedKeyterm == "testflight" {
            forms.append("TestFly")
        }
        if lowercasedKeyterm == "sqlite" {
            forms.append(contentsOf: ["SQ Lite", "UseSqlite"])
        }
        if lowercasedKeyterm == "userdefaults" {
            forms.append(contentsOf: ["UserDefault", "User Default", "User Defaults"])
        }
        if lowercasedKeyterm == "rest api" {
            forms.append("RESTAPI")
        }
        if lowercasedKeyterm == "pull request" {
            forms.append("pool request")
        }

        return forms
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

    private static func wholeTermPattern(for term: String) -> String {
        let tokens = alphanumericTokens(in: term)
        guard !tokens.isEmpty else {
            return "(?!)"
        }

        let body = tokens.map(tokenPattern).joined(separator: flexibleSeparatorPattern)
        let prefixGuard = term.lowercased() == "store connect" ? "(?<!APP )" : ""
        let leadingBoundary = term.hasPrefix(".") ? "(?<![A-Za-z0-9.])" : "(?<![A-Za-z0-9])"
        let dotPrefix = term.hasPrefix(".") ? #"(?:\.|dot|period|punto)\s*"# : ""
        return "\(leadingBoundary)\(prefixGuard)\(dotPrefix)\(body)(?![A-Za-z0-9])"
    }

    private static var flexibleSeparatorPattern: String {
        #"(?:[\s._,;:\-]+|\s*(?:dot|period|punto|dash|hyphen|underscore)\s*)+"#
    }

    private static func alphanumericTokens(in term: String) -> [String] {
        SpeechConfusionCatalog.alphanumericTokens(in: term)
    }

    private static func normalizedRecognitionKey(_ term: String) -> String {
        alphanumericTokens(in: term).joined(separator: " ").lowercased()
    }

    private static func tokenPattern(for token: String) -> String {
        guard token.count <= 4, token.allSatisfy(\.isLetter) else {
            return NSRegularExpression.escapedPattern(for: token)
        }

        // No trailing `\.?`: consuming a sentence-ending period made every
        // correction at the end of a sentence eat the period ("Instala git.
        // Luego…" → "Instala git Luego…"). The trailing lookahead already
        // treats "." as a boundary, so the period survives outside the match.
        let characters = token.map { NSRegularExpression.escapedPattern(for: String($0)) }
        return characters.joined(separator: #"[\s._-]*"#)
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
