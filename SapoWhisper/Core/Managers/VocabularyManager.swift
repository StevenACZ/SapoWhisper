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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        keyterms = (json["keyterms"] as? [String]) ?? []
        replacements = (json["replacements"] as? [String: String]) ?? [:]
    }

    private func save() {
        let json: [String: Any] = [
            "keyterms": keyterms,
            "replacements": replacements
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

    // MARK: - Query Parameters for Deepgram

    /// Returns keyterm query items for Deepgram WebSocket URL
    func keytermQueryItems() -> [URLQueryItem] {
        keyterms.map { URLQueryItem(name: "keyterm", value: $0) }
    }

    /// Returns replace query items for Deepgram WebSocket URL
    func replaceQueryItems() -> [URLQueryItem] {
        replacements.map { URLQueryItem(name: "replace", value: "\($0.key):\($0.value)") }
    }
}
