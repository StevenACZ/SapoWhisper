import Foundation

extension SettingsTransferManager {
    func currentPreferences() -> SettingsTransferPreferences {
        var preferences = SettingsTransferPreferences(
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
            localAIServerBaseURL: defaults.string(forKey: Constants.StorageKeys.localAIServerBaseURL)
                .flatMap(ProviderURLSecurity.sanitizedValidURLString),
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
                .flatMap(ProviderURLSecurity.sanitizedValidURLString)
        )
        preferences.fallbackTranscriptionEngine =
            TranscriptionEngineVariant.stored(
                defaults.string(forKey: Constants.StorageKeys.fallbackTranscriptionEngine) ?? "")?.rawValue ?? ""
        preferences.historyAudioMaxMB = intValue(
            forKey: Constants.StorageKeys.historyAudioMaxMB, defaultValue: HistoryAudioStorage.defaultMaxStorageMB)
        preferences.historyAutoDeleteDays = intValue(forKey: Constants.StorageKeys.historyAutoDeleteDays, defaultValue: 0)
        preferences.overlayPosition = defaults.string(forKey: Constants.StorageKeys.overlayPosition) ?? OverlayPosition.bottom.rawValue
        preferences.autoUpdateCheckEnabled = boolValue(forKey: Constants.StorageKeys.autoUpdateCheckEnabled, defaultValue: true)
        preferences.mlxWhisperUnloadAfterMinutes = intValue(forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes, defaultValue: 0)
        preferences.aiPolishMode = PolishMode.current(defaults: defaults).rawValue
        preferences.aiPolishMinDuration = PolishMinimumDuration.current(defaults: defaults).rawValue
        preferences.aiPolishReasoningEffort =
            defaults.string(forKey: Constants.StorageKeys.aiPolishReasoningEffort) ?? PolishReasoningEffort.default.rawValue
        preferences.aiPolishQuickTranslationTarget = defaults.string(forKey: Constants.StorageKeys.aiPolishQuickTranslationTarget)
        preferences.polishProviderModels = Dictionary(
            uniqueKeysWithValues: PolishEndpoint.allCases.map {
                ($0.rawValue, PolishProviderConfiguration.storedModel(for: $0, defaults: defaults))
            })
        preferences.polishProviderBaseURLs = Dictionary(
            uniqueKeysWithValues: PolishEndpoint.allCases.compactMap { endpoint in
                guard endpoint.usesEditableBaseURL,
                    let url = ProviderURLSecurity.sanitizedValidURLString(
                        PolishProviderConfiguration.storedBaseURLInput(for: endpoint, defaults: defaults))
                else { return nil }
                return (endpoint.rawValue, url)
            })
        return preferences
    }

    func importPreferences(_ preferences: SettingsTransferPreferences, sections: Set<SettingsTransferSection>) {
        if sections.contains(.history) {
            setIfPresent(preferences.historyAudioMaxMB, key: Constants.StorageKeys.historyAudioMaxMB)
            setIfPresent(preferences.historyAutoDeleteDays, key: Constants.StorageKeys.historyAutoDeleteDays)
        }
        if sections.contains(.behavior) {
            setIfPresent(preferences.overlayPosition, key: Constants.StorageKeys.overlayPosition)
            setIfPresent(preferences.autoUpdateCheckEnabled, key: Constants.StorageKeys.autoUpdateCheckEnabled)
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
            setIfPresent(
                preferences.fallbackTranscriptionEngine.map { TranscriptionEngineVariant.stored($0)?.rawValue ?? "" },
                key: Constants.StorageKeys.fallbackTranscriptionEngine)
            setIfPresent(preferences.mlxWhisperUnloadAfterMinutes, key: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes)
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
            if let baseURL = preferences.localAIServerBaseURL,
                let sanitized = ProviderURLSecurity.sanitizedValidURLString(baseURL)
            {
                LocalAIServerConfiguration.setStoredBaseURL(sanitized, defaults: defaults)
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
            setIfPresent(preferences.aiPolishMode.map { $0 == "automatic" ? "normal" : $0 }, key: Constants.StorageKeys.aiPolishMode)
            setIfPresent(preferences.aiPolishMinDuration, key: Constants.StorageKeys.aiPolishMinDuration)
            setIfPresent(preferences.aiPolishReasoningEffort, key: Constants.StorageKeys.aiPolishReasoningEffort)
            setIfPresent(preferences.aiPolishQuickTranslationTarget, key: Constants.StorageKeys.aiPolishQuickTranslationTarget)
            defaults.set(preferences.aiPolishEnabled, forKey: Constants.StorageKeys.aiPolishEnabled)
            defaults.set(preferences.aiPolishOutputLanguage, forKey: Constants.StorageKeys.aiPolishOutputLanguage)
            if let endpoint = preferences.aiPolishEndpoint {
                defaults.set(endpoint, forKey: Constants.StorageKeys.aiPolishEndpoint)
            }
            if let model = preferences.aiPolishModel {
                defaults.set(model, forKey: Constants.StorageKeys.aiPolishModel)
            }
            if let customBaseURL = preferences.aiPolishCustomBaseURL,
                let sanitized = ProviderURLSecurity.sanitizedValidURLString(customBaseURL)
            {
                PolishProviderConfiguration.setStoredBaseURLInput(
                    sanitized,
                    for: .custom,
                    defaults: defaults
                )
            }
            for (raw, model) in preferences.polishProviderModels ?? [:] {
                if let endpoint = PolishEndpoint(rawValue: raw) {
                    PolishProviderConfiguration.setStoredModel(model, for: endpoint, defaults: defaults)
                }
            }
            for (raw, value) in preferences.polishProviderBaseURLs ?? [:] {
                if let endpoint = PolishEndpoint(rawValue: raw), let url = ProviderURLSecurity.sanitizedValidURLString(value) {
                    PolishProviderConfiguration.setStoredBaseURLInput(url, for: endpoint, defaults: defaults)
                }
            }
        }
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
    private func setIfPresent<T>(_ value: T?, key: String) {
        if let value { defaults.set(value, forKey: key) }
    }
}

extension SettingsTransferManager {
    static var portablePreferenceSections: [String: SettingsTransferSection] {
        typealias Keys = Constants.StorageKeys
        let groups: [SettingsTransferSection: [String]] = [
            .behavior: [Keys.appLanguage, Keys.language, Keys.autoPaste, Keys.overlayPosition, Keys.autoUpdateCheckEnabled],
            .audio: [
                Keys.playSound, Keys.soundVolume, Keys.autoDuckingEnabled, Keys.autoDuckingAmount, Keys.audioGain, Keys.audioUploadQuality,
            ],
            .engine: [
                Keys.transcriptionEngine, Keys.fallbackTranscriptionEngine, Keys.mlxWhisperModel,
                Keys.mlxWhisperUnloadAfterMinutes, Keys.deepgramTranscriptionMode, Keys.elevenLabsTranscriptionMode,
                Keys.localAIServerBaseURL, Keys.localAIServerModel,
            ],
            .history: [Keys.historyAudioMaxMB, Keys.historyAutoDeleteDays],
            .hotkey: [Keys.hotkeyTriggerKind, Keys.hotkeyKeyCode, Keys.hotkeyModifiers, Keys.hotkeyDoubleTapModifier],
            .aiPolish: [
                Keys.aiPolishEnabled, Keys.aiPolishOutputLanguage, Keys.aiPolishEndpoint, Keys.aiPolishModel,
                Keys.aiPolishCustomBaseURL, Keys.aiPolishMode, Keys.aiPolishMinDuration, Keys.aiPolishReasoningEffort,
                Keys.aiPolishQuickTranslationTarget,
            ],
        ]
        var result = Dictionary(uniqueKeysWithValues: groups.flatMap { section, keys in keys.map { ($0, section) } })
        for endpoint in PolishEndpoint.allCases {
            result[Keys.aiPolishEndpointModelPrefix + endpoint.rawValue] = .aiPolish
            if endpoint.usesEditableBaseURL {
                result[Keys.aiPolishEndpointBaseURLPrefix + endpoint.rawValue] = .aiPolish
            }
        }
        return result
    }
}
