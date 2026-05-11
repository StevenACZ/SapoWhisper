//
//  VocabularyManager.swift
//  SapoWhisper
//

import Combine
import Foundation

/// Manages keyterms and replacements for Deepgram speech recognition
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
                let escaped = NSRegularExpression.escapedPattern(for: replacement.key)
                let pattern = "\\b\(escaped)\\b"
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
}
