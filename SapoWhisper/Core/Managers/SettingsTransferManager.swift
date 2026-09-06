//
//  SettingsTransferManager.swift
//  SapoWhisper
//

import Foundation

struct VocabularySnapshot: Codable, Equatable {
    var keyterms: [String]
    var replacements: [String: String]
    var includeReplacementTargetsInRecognitionHints: Bool? = nil
}

struct SettingsTransferDocument: Codable, Identifiable {
    var schemaVersion: Int
    var appVersion: String
    var exportedAt: Date
    var preferences: SettingsTransferPreferences?
    var vocabulary: VocabularySnapshot?
    var promptContext: PromptContextSnapshot?
    var apiKeys: SettingsTransferAPIKeys?
    var unsetPreferenceKeys: [String]? = nil

    var id: String {
        "\(schemaVersion)-\(exportedAt.timeIntervalSince1970)"
    }
}

struct SettingsTransferPreferences: Codable, Equatable {
    var appLanguage: String
    var transcriptionLanguage: String
    var autoPaste: Bool
    var playSound: Bool
    var soundVolume: Double
    var autoDuckingEnabled: Bool
    var autoDuckingAmount: Double
    var transcriptionEngine: String
    /// Optional: absent in exports older than the MLX engine (2026-07-06).
    var mlxWhisperModel: String?
    var deepgramTranscriptionMode: String
    var elevenLabsTranscriptionMode: String?
    var localAIServerBaseURL: String?
    var localAIServerModel: String?
    var hotkeyTriggerKind: String?
    var hotkeyKeyCode: Int
    var hotkeyModifiers: Int
    var hotkeyDoubleTapModifier: Int?
    var audioGain: Double
    var audioUploadQuality: String?
    var aiPolishEnabled: Bool
    var aiPolishOutputLanguage: String
    var aiPolishEndpoint: String?
    var aiPolishModel: String?
    var aiPolishCustomBaseURL: String?
    var fallbackTranscriptionEngine: String? = nil
    var historyAudioMaxMB: Int? = nil
    var historyAutoDeleteDays: Int? = nil
    var overlayPosition: String? = nil
    var autoUpdateCheckEnabled: Bool? = nil
    var mlxWhisperUnloadAfterMinutes: Int? = nil
    var aiPolishMode: String? = nil
    var aiPolishMinDuration: Int? = nil
    var aiPolishReasoningEffort: String? = nil
    var aiPolishQuickTranslationTarget: String? = nil
    var polishProviderModels: [String: String]? = nil
    var polishProviderBaseURLs: [String: String]? = nil
}

/// Legacy section: old export files may still carry plaintext engine keys.
/// New exports never include them; importing routes them to the Keychain.
struct SettingsTransferAPIKeys: Codable, Equatable {
    var deepgramAPIKey: String?
    var elevenLabsAPIKey: String?

    var isEmpty: Bool {
        (deepgramAPIKey ?? "").isEmpty && (elevenLabsAPIKey ?? "").isEmpty
    }
}

enum SettingsTransferSection: String, CaseIterable, Hashable, Identifiable {
    case behavior
    case history
    case audio
    case engine
    case hotkey
    case aiPolish
    case vocabulary
    case promptContext
    case apiKeys

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .history:
            return "settings.transfer.section_history"
        case .behavior:
            return "settings.transfer.section_behavior"
        case .audio:
            return "settings.transfer.section_audio"
        case .engine:
            return "settings.transfer.section_engine"
        case .hotkey:
            return "settings.transfer.section_hotkey"
        case .aiPolish:
            return "settings.transfer.section_ai"
        case .vocabulary:
            return "settings.transfer.section_vocabulary"
        case .promptContext:
            return "settings.transfer.section_prompt_context"
        case .apiKeys:
            return "settings.transfer.section_api_keys"
        }
    }

    var descriptionKey: String {
        switch self {
        case .history:
            return "settings.transfer.section_history_desc"
        case .behavior:
            return "settings.transfer.section_behavior_desc"
        case .audio:
            return "settings.transfer.section_audio_desc"
        case .engine:
            return "settings.transfer.section_engine_desc"
        case .hotkey:
            return "settings.transfer.section_hotkey_desc"
        case .aiPolish:
            return "settings.transfer.section_ai_desc"
        case .vocabulary:
            return "settings.transfer.section_vocabulary_desc"
        case .promptContext:
            return "settings.transfer.section_prompt_context_desc"
        case .apiKeys:
            return "settings.transfer.section_api_keys_desc"
        }
    }
}

enum SettingsTransferError: LocalizedError {
    case emptyImportSelection
    case missingVocabulary
    case invalidDocument
    case importFileWriteFailed(URL)
    case importRollbackFailed(URL)
    case unsupportedSchema(Int)
    case apiKeysNotStored(Int)

    var errorDescription: String? {
        switch self {
        case .emptyImportSelection:
            return "No import sections selected"
        case .importFileWriteFailed(let backupURL):
            return "settings.transfer.file_write_failed".localized(backupURL.path)
        case .importRollbackFailed(let backupURL):
            return "settings.transfer.rollback_failed".localized(backupURL.path)
        case .invalidDocument:
            return "settings.transfer.invalid_document".localized
        case .missingVocabulary:
            return "The selected file does not contain vocabulary data"
        case .unsupportedSchema(let version):
            return "Unsupported settings file version: \(version)"
        case .apiKeysNotStored(let count):
            return "\(count) API key(s) could not be saved to the Keychain; the rest of the settings were imported"
        }
    }
}

struct SettingsTransferManager {
    static let shared = SettingsTransferManager()

    let defaults: UserDefaults
    let readEngineKey: (KeychainStore.Key) -> String?
    private let vocabularyManager: VocabularyManager
    private let promptContextManager: PromptContextManager
    private let backupDirectory: URL
    private let writeEngineKey: (String, KeychainStore.Key) -> Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = AppPreferences.defaults,
        vocabularyManager: VocabularyManager = .shared,
        promptContextManager: PromptContextManager = .shared,
        backupDirectory: URL = AppRuntimePaths.applicationSupport.appendingPathComponent("SettingsBackups", isDirectory: true),
        readEngineKey: @escaping (KeychainStore.Key) -> String? = {
            // Presence check only (call sites test isEmpty), so gate on hasValue and
            // never trigger the macOS Keychain consent prompt on import — mirrors
            // EnginePortfolioMigration. The non-nil sentinel is intentionally opaque.
            KeychainStore.hasValue(for: $0) ? "present" : nil
        },
        writeEngineKey: @escaping (String, KeychainStore.Key) -> Bool = {
            KeychainStore.setString($0, for: $1)
        }
    ) {
        self.defaults = defaults
        self.vocabularyManager = vocabularyManager
        self.promptContextManager = promptContextManager
        self.backupDirectory = backupDirectory
        self.readEngineKey = readEngineKey
        self.writeEngineKey = writeEngineKey

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func encodedSettings() throws -> Data {
        try encoder.encode(makeSettingsDocument())
    }

    func encodedVocabulary() throws -> Data {
        let document = SettingsTransferDocument(
            schemaVersion: 1,
            appVersion: Constants.appVersion,
            exportedAt: Date(),
            preferences: nil,
            vocabulary: vocabularyManager.snapshot(),
            promptContext: nil,
            apiKeys: nil
        )
        return try encoder.encode(document)
    }

    func decodedDocument(from data: Data) throws -> SettingsTransferDocument {
        let document = try decoder.decode(SettingsTransferDocument.self, from: data)
        guard document.schemaVersion == 1 else {
            throw SettingsTransferError.unsupportedSchema(document.schemaVersion)
        }
        try validate(document, sections: [])
        return document
    }

    func availableSections(in document: SettingsTransferDocument) -> [SettingsTransferSection] {
        var sections: [SettingsTransferSection] = []
        if document.preferences != nil {
            sections.append(contentsOf: [.behavior, .audio, .engine, .hotkey, .aiPolish])
        }
        if document.preferences?.historyAudioMaxMB != nil || document.preferences?.historyAutoDeleteDays != nil {
            sections.append(.history)
        }
        if document.vocabulary != nil {
            sections.append(.vocabulary)
        }
        if document.promptContext != nil {
            sections.append(.promptContext)
        }
        if let apiKeys = document.apiKeys, !apiKeys.isEmpty {
            sections.append(.apiKeys)
        }
        return sections
    }

    func defaultImportSections(for document: SettingsTransferDocument) -> Set<SettingsTransferSection> {
        Set(availableSections(in: document).filter { $0 != .apiKeys && $0 != .history })
    }

    @discardableResult
    func importDocument(
        _ document: SettingsTransferDocument,
        sections: Set<SettingsTransferSection>,
        vocabularyMode: VocabularyImportMode = .combine
    ) throws -> URL {
        try validate(document, sections: sections)
        guard !sections.isEmpty else {
            throw SettingsTransferError.emptyImportSelection
        }

        let previous = makeSettingsDocument()
        let backupURL = try SettingsTransferBackup.write(encoder.encode(previous), directory: backupDirectory)
        try importFileSections(document, previous: previous, sections: sections, vocabularyMode: vocabularyMode, backupURL: backupURL)

        if let preferences = document.preferences {
            importPreferences(preferences, sections: sections)
            for key in document.unsetPreferenceKeys ?? [] where Self.portablePreferenceSections[key].map(sections.contains) == true {
                defaults.removeObject(forKey: key)
            }
        }

        if sections.contains(.apiKeys), let apiKeys = document.apiKeys {
            let notStored = importAPIKeys(apiKeys)
            guard notStored == 0 else {
                throw SettingsTransferError.apiKeysNotStored(notStored)
            }
        }
        return backupURL
    }

    func importVocabulary(from document: SettingsTransferDocument, mode: VocabularyImportMode = .combine) throws {
        _ = try importDocument(document, sections: [.vocabulary], vocabularyMode: mode)
    }

    private func importFileSections(
        _ document: SettingsTransferDocument,
        previous: SettingsTransferDocument,
        sections: Set<SettingsTransferSection>,
        vocabularyMode: VocabularyImportMode,
        backupURL: URL
    ) throws {
        var vocabularyChanged = false
        do {
            if sections.contains(.vocabulary), let incoming = document.vocabulary, let existing = previous.vocabulary {
                try vocabularyManager.replacePersisting(with: vocabularyMode.snapshot(importing: incoming, into: existing))
                vocabularyChanged = true
            }
            if sections.contains(.promptContext), let context = document.promptContext {
                try promptContextManager.replacePersisting(with: context)
            }
        } catch {
            if vocabularyChanged, let vocabulary = previous.vocabulary {
                do {
                    try vocabularyManager.replacePersisting(with: vocabulary)
                } catch {
                    throw SettingsTransferError.importRollbackFailed(backupURL)
                }
            }
            throw SettingsTransferError.importFileWriteFailed(backupURL)
        }
    }

    private func makeSettingsDocument() -> SettingsTransferDocument {
        // API keys are never exported: shareable JSON must not carry secrets.
        SettingsTransferDocument(
            schemaVersion: 1,
            appVersion: Constants.appVersion,
            exportedAt: Date(),
            preferences: currentPreferences(),
            vocabulary: vocabularyManager.snapshot(),
            promptContext: promptContextManager.snapshot(),
            apiKeys: nil,
            unsetPreferenceKeys: Self.portablePreferenceSections.keys.filter { defaults.object(forKey: $0) == nil }.sorted()
        )
    }

    /// Keys from legacy export files land in the Keychain, never UserDefaults.
    /// Returns how many never made it there — a denied keychain read turns the
    /// write into a silent no-op, and the import must not report success.
    private func importAPIKeys(_ apiKeys: SettingsTransferAPIKeys) -> Int {
        var notStored = 0
        if let deepgramAPIKey = emptyStringAsNil(apiKeys.deepgramAPIKey), !writeEngineKey(deepgramAPIKey, .deepgramAPIKey) {
            notStored += 1
        }
        if let elevenLabsAPIKey = emptyStringAsNil(apiKeys.elevenLabsAPIKey),
            !writeEngineKey(elevenLabsAPIKey, .elevenLabsAPIKey)
        {
            notStored += 1
        }
        return notStored
    }

    private func emptyStringAsNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

}

enum VocabularyImportMode: String, CaseIterable, Identifiable {
    case combine
    case replace

    var id: String { rawValue }

    func snapshot(importing incoming: VocabularySnapshot, into existing: VocabularySnapshot) -> VocabularySnapshot {
        guard self == .combine else { return incoming }
        var result = existing
        for term in incoming.keyterms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.keyterms.contains(trimmed) { result.keyterms.append(trimmed) }
        }
        for original in incoming.replacements.keys.sorted() {
            let key = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = incoming.replacements[original]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !key.isEmpty, !value.isEmpty, result.replacements[key] == nil { result.replacements[key] = value }
        }
        return result
    }
}

extension SettingsTransferManager {
    func validate(_ document: SettingsTransferDocument, sections: Set<SettingsTransferSection>) throws {
        guard document.schemaVersion == 1 else {
            throw SettingsTransferError.unsupportedSchema(document.schemaVersion)
        }
        if sections.contains(.vocabulary), document.vocabulary == nil { throw SettingsTransferError.missingVocabulary }
        guard sections.isSubset(of: Set(availableSections(in: document))) else {
            throw SettingsTransferError.invalidDocument
        }
        if let unsetKeys = document.unsetPreferenceKeys {
            guard document.preferences != nil,
                unsetKeys.allSatisfy({ Self.portablePreferenceSections[$0] != nil })
            else { throw SettingsTransferError.invalidDocument }
        }
        if let preferences = document.preferences { try validate(preferences) }
        if let vocabulary = document.vocabulary {
            let keys = vocabulary.replacements.keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard Set(keys).count == keys.count,
                keys.allSatisfy({ !$0.isEmpty }),
                vocabulary.replacements.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { throw SettingsTransferError.invalidDocument }
        }
        if let context = document.promptContext, context.personalContext.details.count > 2_000 {
            throw SettingsTransferError.invalidDocument
        }
    }

    private func validate(_ preferences: SettingsTransferPreferences) throws {
        guard preferences.soundVolume.isFinite, (0...1).contains(preferences.soundVolume),
            preferences.autoDuckingAmount.isFinite, (0...1).contains(preferences.autoDuckingAmount),
            preferences.audioGain.isFinite, (1...40).contains(preferences.audioGain),
            preferences.historyAudioMaxMB.map({ $0 > 0 && $0 <= Int.max / 1_048_576 }) ?? true,
            preferences.historyAutoDeleteDays.map({ $0 >= 0 && $0 <= 365_000 }) ?? true,
            preferences.mlxWhisperUnloadAfterMinutes.map({ [0, 15, 30, 60].contains($0) }) ?? true,
            preferences.aiPolishMinDuration.map({ PolishMinimumDuration(rawValue: $0) != nil }) ?? true,
            preferences.fallbackTranscriptionEngine.map({ $0.isEmpty || TranscriptionEngineVariant.stored($0) != nil }) ?? true,
            preferences.overlayPosition.map({ OverlayPosition(rawValue: $0) != nil }) ?? true,
            preferences.aiPolishMode.map({ $0 == "automatic" || PolishMode(rawValue: $0) != nil }) ?? true,
            preferences.aiPolishReasoningEffort.map({ PolishReasoningEffort(rawValue: $0) != nil }) ?? true,
            preferences.aiPolishEndpoint.map({ PolishEndpoint(rawValue: $0) != nil }) ?? true,
            DeepgramTranscriptionMode(rawValue: preferences.deepgramTranscriptionMode) != nil,
            preferences.elevenLabsTranscriptionMode.map({ ElevenLabsTranscriptionMode(rawValue: $0) != nil }) ?? true,
            preferences.mlxWhisperModel.map({ MLXWhisperModel(rawValue: $0) != nil }) ?? true,
            preferences.audioUploadQuality.map({ AudioUploadQuality(rawValue: $0) != nil }) ?? true,
            preferences.polishProviderModels.map({ $0.keys.allSatisfy { PolishEndpoint(rawValue: $0) != nil } }) ?? true,
            preferences.polishProviderBaseURLs.map({ $0.keys.allSatisfy { PolishEndpoint(rawValue: $0) != nil } }) ?? true
        else { throw SettingsTransferError.invalidDocument }
    }
}
