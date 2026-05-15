//
//  SettingsTransferManager.swift
//  SapoWhisper
//

import Foundation

struct VocabularySnapshot: Codable, Equatable {
    var keyterms: [String]
    var replacements: [String: String]
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
    var whisperKitModel: String
    var deepgramTranscriptionMode: String
    var geminiAudioModel: String?
    var hotkeyKeyCode: Int
    var hotkeyModifiers: Int
    var audioGain: Double
    var aiPolishEnabled: Bool
    var aiPolishMode: String
    var aiPolishOutputLanguage: String
    var aiPolishMinimumDuration: String?
}

struct SettingsTransferAPIKeys: Codable, Equatable {
    var deepgramAPIKey: String?
    var googleCloudAPIKey: String?

    var isEmpty: Bool {
        (deepgramAPIKey ?? "").isEmpty && (googleCloudAPIKey ?? "").isEmpty
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

    var errorDescription: String? {
        switch self {
        case .emptyImportSelection:
            return "No import sections selected"
        case .missingVocabulary:
            return "The selected file does not contain vocabulary data"
        case .unsupportedSchema(let version):
            return "Unsupported settings file version: \(version)"
        }
    }
}

struct SettingsTransferManager {
    static let shared = SettingsTransferManager()

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func encodedSettings(includeAPIKeys: Bool) throws -> Data {
        try encoder.encode(makeSettingsDocument(includeAPIKeys: includeAPIKeys))
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
            importAPIKeys(apiKeys)
        }
    }

    func importVocabulary(from document: SettingsTransferDocument) throws {
        guard let vocabulary = document.vocabulary else {
            throw SettingsTransferError.missingVocabulary
        }
        VocabularyManager.shared.merge(snapshot: vocabulary)
    }

    private func makeSettingsDocument(includeAPIKeys: Bool) -> SettingsTransferDocument {
        let apiKeys = includeAPIKeys ? currentAPIKeys() : nil
        return SettingsTransferDocument(
            schemaVersion: 1,
            appVersion: Constants.appVersion,
            exportedAt: Date(),
            preferences: currentPreferences(),
            vocabulary: VocabularyManager.shared.snapshot(),
            promptContext: PromptContextManager.shared.snapshot(),
            apiKeys: apiKeys?.isEmpty == true ? nil : apiKeys
        )
    }

    private func currentPreferences() -> SettingsTransferPreferences {
        SettingsTransferPreferences(
            appLanguage: defaults.string(forKey: Constants.StorageKeys.appLanguage) ?? "es",
            transcriptionLanguage: defaults.string(forKey: Constants.StorageKeys.language) ?? "es",
            autoPaste: boolValue(forKey: Constants.StorageKeys.autoPaste, defaultValue: true),
            playSound: boolValue(forKey: Constants.StorageKeys.playSound, defaultValue: true),
            soundVolume: doubleValue(forKey: Constants.StorageKeys.soundVolume, defaultValue: 1.0),
            autoDuckingEnabled: boolValue(forKey: Constants.StorageKeys.autoDuckingEnabled, defaultValue: false),
            autoDuckingAmount: doubleValue(forKey: Constants.StorageKeys.autoDuckingAmount, defaultValue: 0.8),
            transcriptionEngine: defaults.string(forKey: Constants.StorageKeys.transcriptionEngine)
                ?? TranscriptionEngine.appleOnline.rawValue,
            whisperKitModel: defaults.string(forKey: Constants.StorageKeys.whisperKitModel)
                ?? WhisperKitModel.small.rawValue,
            deepgramTranscriptionMode: defaults.string(forKey: Constants.StorageKeys.deepgramTranscriptionMode)
                ?? DeepgramTranscriptionMode.nova3.rawValue,
            geminiAudioModel: defaults.string(forKey: Constants.StorageKeys.geminiAudioModel)
                ?? GeminiAudioModel.defaultModel.rawValue,
            hotkeyKeyCode: intValue(forKey: Constants.StorageKeys.hotkeyKeyCode, defaultValue: Int(Constants.Hotkey.defaultKeyCode)),
            hotkeyModifiers: intValue(forKey: Constants.StorageKeys.hotkeyModifiers, defaultValue: Int(Constants.Hotkey.defaultModifiers)),
            audioGain: doubleValue(forKey: Constants.StorageKeys.audioGain, defaultValue: 1.0),
            aiPolishEnabled: boolValue(forKey: Constants.StorageKeys.aiPolishEnabled, defaultValue: false),
            aiPolishMode: defaults.string(forKey: Constants.StorageKeys.aiPolishMode)
                ?? TranscriptPolishMode.automatic.rawValue,
            aiPolishOutputLanguage: defaults.string(forKey: Constants.StorageKeys.aiPolishOutputLanguage)
                ?? TranscriptPolishOutputLanguage.sameAsInput.rawValue,
            aiPolishMinimumDuration: defaults.string(forKey: Constants.StorageKeys.aiPolishMinimumDuration)
                ?? TranscriptPolishMinimumDuration.defaultPolicy.rawValue
        )
    }

    private func currentAPIKeys() -> SettingsTransferAPIKeys {
        SettingsTransferAPIKeys(
            deepgramAPIKey: emptyStringAsNil(defaults.string(forKey: Constants.StorageKeys.deepgramAPIKey)),
            googleCloudAPIKey: emptyStringAsNil(defaults.string(forKey: Constants.StorageKeys.googleCloudAPIKey))
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
        }

        if sections.contains(.engine) {
            defaults.set(preferences.transcriptionEngine, forKey: Constants.StorageKeys.transcriptionEngine)
            defaults.set(preferences.whisperKitModel, forKey: Constants.StorageKeys.whisperKitModel)
            defaults.set(preferences.deepgramTranscriptionMode, forKey: Constants.StorageKeys.deepgramTranscriptionMode)
            defaults.set(
                preferences.geminiAudioModel ?? GeminiAudioModel.defaultModel.rawValue,
                forKey: Constants.StorageKeys.geminiAudioModel
            )
        }

        if sections.contains(.hotkey) {
            defaults.set(preferences.hotkeyKeyCode, forKey: Constants.StorageKeys.hotkeyKeyCode)
            defaults.set(preferences.hotkeyModifiers, forKey: Constants.StorageKeys.hotkeyModifiers)
            HotkeyManager.shared.updateHotkey(
                keyCode: UInt32(preferences.hotkeyKeyCode),
                modifiers: UInt32(preferences.hotkeyModifiers)
            )
        }

        if sections.contains(.aiPolish) {
            defaults.set(preferences.aiPolishEnabled, forKey: Constants.StorageKeys.aiPolishEnabled)
            defaults.set(preferences.aiPolishMode, forKey: Constants.StorageKeys.aiPolishMode)
            defaults.set(preferences.aiPolishOutputLanguage, forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            defaults.set(
                preferences.aiPolishMinimumDuration ?? TranscriptPolishMinimumDuration.defaultPolicy.rawValue,
                forKey: Constants.StorageKeys.aiPolishMinimumDuration
            )
        }
    }

    private func importAPIKeys(_ apiKeys: SettingsTransferAPIKeys) {
        if let deepgramAPIKey = apiKeys.deepgramAPIKey {
            defaults.set(deepgramAPIKey, forKey: Constants.StorageKeys.deepgramAPIKey)
        }
        if let googleCloudAPIKey = apiKeys.googleCloudAPIKey {
            defaults.set(googleCloudAPIKey, forKey: Constants.StorageKeys.googleCloudAPIKey)
        }
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
