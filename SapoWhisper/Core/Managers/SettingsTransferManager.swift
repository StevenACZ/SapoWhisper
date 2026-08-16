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
    case unsupportedSchema(Int)
    case apiKeysNotStored(Int)

    var errorDescription: String? {
        switch self {
        case .emptyImportSelection:
            return "No import sections selected"
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

    private let defaults: UserDefaults
    private let readEngineKey: (KeychainStore.Key) -> String?
    private let writeEngineKey: (String, KeychainStore.Key) -> Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
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
            vocabulary: VocabularyManager.shared.snapshot(),
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
        return document
    }

    func availableSections(in document: SettingsTransferDocument) -> [SettingsTransferSection] {
        var sections: [SettingsTransferSection] = []
        if document.preferences != nil {
            sections.append(contentsOf: [.behavior, .audio, .engine, .hotkey, .aiPolish])
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
        Set(availableSections(in: document).filter { $0 != .apiKeys })
    }

    func importDocument(_ document: SettingsTransferDocument, sections: Set<SettingsTransferSection>) throws {
        guard !sections.isEmpty else {
            throw SettingsTransferError.emptyImportSelection
        }

        if let preferences = document.preferences {
            importPreferences(preferences, sections: sections)
        }

        if sections.contains(.vocabulary) {
            guard let vocabulary = document.vocabulary else {
                throw SettingsTransferError.missingVocabulary
            }
            VocabularyManager.shared.merge(snapshot: vocabulary)
        }

        if sections.contains(.promptContext), let promptContext = document.promptContext {
            PromptContextManager.shared.replace(with: promptContext)
        }

        if sections.contains(.apiKeys), let apiKeys = document.apiKeys {
            let notStored = importAPIKeys(apiKeys)
            guard notStored == 0 else {
                throw SettingsTransferError.apiKeysNotStored(notStored)
            }
        }
    }

    func importVocabulary(from document: SettingsTransferDocument) throws {
        guard let vocabulary = document.vocabulary else {
            throw SettingsTransferError.missingVocabulary
        }
        VocabularyManager.shared.merge(snapshot: vocabulary)
    }

    private func makeSettingsDocument() -> SettingsTransferDocument {
        // API keys are never exported: shareable JSON must not carry secrets.
        SettingsTransferDocument(
            schemaVersion: 1,
            appVersion: Constants.appVersion,
            exportedAt: Date(),
            preferences: currentPreferences(),
            vocabulary: VocabularyManager.shared.snapshot(),
            promptContext: PromptContextManager.shared.snapshot(),
            apiKeys: nil
        )
    }

    private func currentPreferences() -> SettingsTransferPreferences {
        SettingsTransferPreferences(
            appLanguage: defaults.string(forKey: Constants.StorageKeys.appLanguage)
                ?? LocalizationManager.systemDefaultLanguage,
            transcriptionLanguage: defaults.string(forKey: Constants.StorageKeys.language) ?? "auto",
            autoPaste: boolValue(forKey: Constants.StorageKeys.autoPaste, defaultValue: true),
            playSound: boolValue(forKey: Constants.StorageKeys.playSound, defaultValue: true),
            soundVolume: doubleValue(forKey: Constants.StorageKeys.soundVolume, defaultValue: 1.0),
            autoDuckingEnabled: boolValue(forKey: Constants.StorageKeys.autoDuckingEnabled, defaultValue: false),
            autoDuckingAmount: doubleValue(forKey: Constants.StorageKeys.autoDuckingAmount, defaultValue: 0.8),
            transcriptionEngine: defaults.string(forKey: Constants.StorageKeys.transcriptionEngine)
                ?? TranscriptionEngine.mlxWhisper.rawValue,
            mlxWhisperModel: defaults.string(forKey: Constants.StorageKeys.mlxWhisperModel)
                ?? MLXWhisperModel.largeV3Turbo.rawValue,
            deepgramTranscriptionMode: defaults.string(forKey: Constants.StorageKeys.deepgramTranscriptionMode)
                ?? DeepgramTranscriptionMode.nova3.rawValue,
            elevenLabsTranscriptionMode: defaults.string(forKey: Constants.StorageKeys.elevenLabsTranscriptionMode)
                ?? ElevenLabsTranscriptionMode.defaultMode.rawValue,
            localAIServerBaseURL: defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL),
            localAIServerModel: defaults.string(forKey: Constants.StorageKeys.localAIServerModel)
                ?? LocalAIServerConfiguration.defaultModel,
            hotkeyTriggerKind: defaults.string(forKey: Constants.StorageKeys.hotkeyTriggerKind)
                ?? Constants.Hotkey.defaultTriggerKind,
            hotkeyKeyCode: intValue(forKey: Constants.StorageKeys.hotkeyKeyCode, defaultValue: Int(Constants.Hotkey.defaultKeyCode)),
            hotkeyModifiers: intValue(forKey: Constants.StorageKeys.hotkeyModifiers, defaultValue: Int(Constants.Hotkey.defaultModifiers)),
            hotkeyDoubleTapModifier: intValue(
                forKey: Constants.StorageKeys.hotkeyDoubleTapModifier,
                defaultValue: Int(Constants.Hotkey.defaultDoubleTapModifier)
            ),
            audioGain: doubleValue(forKey: Constants.StorageKeys.audioGain, defaultValue: 1.0),
            audioUploadQuality: AudioUploadQuality.stored(in: defaults).rawValue,
            aiPolishEnabled: boolValue(forKey: Constants.StorageKeys.aiPolishEnabled, defaultValue: false),
            aiPolishOutputLanguage: defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
                ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue,
            aiPolishEndpoint: defaults.string(forKey: Constants.StorageKeys.aiPolishEndpoint)
                ?? PolishEndpoint.default.rawValue,
            aiPolishModel: defaults.string(forKey: Constants.StorageKeys.aiPolishModel),
            aiPolishCustomBaseURL: defaults.string(forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
        )
    }

    private func importPreferences(_ preferences: SettingsTransferPreferences, sections: Set<SettingsTransferSection>) {
        if sections.contains(.behavior) {
            defaults.set(preferences.appLanguage, forKey: Constants.StorageKeys.appLanguage)
            defaults.set(preferences.transcriptionLanguage, forKey: Constants.StorageKeys.language)
            defaults.set(preferences.autoPaste, forKey: Constants.StorageKeys.autoPaste)
            LocalizationManager.shared.language = preferences.appLanguage
        }

        if sections.contains(.audio) {
            defaults.set(preferences.playSound, forKey: Constants.StorageKeys.playSound)
            defaults.set(preferences.soundVolume, forKey: Constants.StorageKeys.soundVolume)
            defaults.set(preferences.autoDuckingEnabled, forKey: Constants.StorageKeys.autoDuckingEnabled)
            defaults.set(preferences.autoDuckingAmount, forKey: Constants.StorageKeys.autoDuckingAmount)
            defaults.set(preferences.audioGain, forKey: Constants.StorageKeys.audioGain)
            let uploadQuality = AudioUploadQuality(rawValue: preferences.audioUploadQuality ?? "") ?? .defaultValue
            defaults.set(uploadQuality.rawValue, forKey: Constants.StorageKeys.audioUploadQuality)
        }

        if sections.contains(.engine) {
            // Old export files may carry removed engines; map them like the launch migration.
            let importedEngine = EnginePortfolioMigration.migratedEngine(
                from: preferences.transcriptionEngine,
                hasDeepgramKey: !(readEngineKey(.deepgramAPIKey) ?? "").isEmpty,
                hasElevenLabsKey: !(readEngineKey(.elevenLabsAPIKey) ?? "").isEmpty
            )
            defaults.set(importedEngine, forKey: Constants.StorageKeys.transcriptionEngine)
            if let mlxModel = preferences.mlxWhisperModel, MLXWhisperModel(rawValue: mlxModel) != nil {
                defaults.set(mlxModel, forKey: Constants.StorageKeys.mlxWhisperModel)
            }
            defaults.set(preferences.deepgramTranscriptionMode, forKey: Constants.StorageKeys.deepgramTranscriptionMode)
            defaults.set(
                preferences.elevenLabsTranscriptionMode ?? ElevenLabsTranscriptionMode.defaultMode.rawValue,
                forKey: Constants.StorageKeys.elevenLabsTranscriptionMode
            )
            if let baseURL = preferences.localAIServerBaseURL {
                defaults.set(baseURL, forKey: Constants.StorageKeys.localAIServerBaseURL)
            }
            defaults.set(
                preferences.localAIServerModel ?? LocalAIServerConfiguration.defaultModel,
                forKey: Constants.StorageKeys.localAIServerModel
            )
        }

        if sections.contains(.hotkey) {
            let triggerKindRaw = preferences.hotkeyTriggerKind ?? Constants.Hotkey.defaultTriggerKind
            let triggerKind = HotkeyTriggerKind(rawValue: triggerKindRaw) ?? .keyCombination
            // Sanitize BEFORE persisting: an unvalidated out-of-range value in
            // UserDefaults traps the UInt32 conversion on the next launch.
            let keyCode = HotkeyManager.sanitizedKeyCode(
                preferences.hotkeyKeyCode, fallback: Constants.Hotkey.defaultKeyCode)
            let modifiers = HotkeyManager.sanitizedModifiers(
                preferences.hotkeyModifiers, fallback: Constants.Hotkey.defaultModifiers)
            let doubleTapModifier = HotkeyManager.sanitizedModifiers(
                preferences.hotkeyDoubleTapModifier ?? Int(Constants.Hotkey.defaultDoubleTapModifier),
                fallback: Constants.Hotkey.defaultDoubleTapModifier
            )
            defaults.set(triggerKind.rawValue, forKey: Constants.StorageKeys.hotkeyTriggerKind)
            defaults.set(Int(keyCode), forKey: Constants.StorageKeys.hotkeyKeyCode)
            defaults.set(Int(modifiers), forKey: Constants.StorageKeys.hotkeyModifiers)
            defaults.set(Int(doubleTapModifier), forKey: Constants.StorageKeys.hotkeyDoubleTapModifier)
            HotkeyManager.shared.updateConfiguration(
                triggerKind: triggerKind,
                keyCode: keyCode,
                modifiers: modifiers,
                doubleTapModifier: doubleTapModifier
            )
        }

        if sections.contains(.aiPolish) {
            defaults.set(preferences.aiPolishEnabled, forKey: Constants.StorageKeys.aiPolishEnabled)
            defaults.set(preferences.aiPolishOutputLanguage, forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            if let endpoint = preferences.aiPolishEndpoint {
                defaults.set(endpoint, forKey: Constants.StorageKeys.aiPolishEndpoint)
            }
            if let model = preferences.aiPolishModel {
                defaults.set(model, forKey: Constants.StorageKeys.aiPolishModel)
            }
            if let customBaseURL = preferences.aiPolishCustomBaseURL {
                defaults.set(customBaseURL, forKey: Constants.StorageKeys.aiPolishCustomBaseURL)
            }
        }
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

    private func boolValue(forKey key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private func doubleValue(forKey key: String, defaultValue: Double) -> Double {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
    }

    private func intValue(forKey key: String, defaultValue: Int) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }
}
