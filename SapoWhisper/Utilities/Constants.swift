//
//  Constants.swift
//  SapoWhisper
//
//

import SwiftUI

/// Constantes globales de la aplicación
nonisolated enum Constants {

    // MARK: - App Info

    static let appName = "SapoWhisper"
    /// Single source of truth: read at runtime from the bundle's
    /// CFBundleShortVersionString (MARKETING_VERSION) so the About tab and
    /// settings export never drift from the shipped version.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let appDescription = "Speech-to-Text 100% local"

    // MARK: - Colores de la Marca

    enum Colors {
        // Colores principales del sapo
        static let sapoGreen = Color(red: 0.298, green: 0.686, blue: 0.314)  // #4CAF50
        static let sapoGreenDark = Color(red: 0.220, green: 0.557, blue: 0.235)  // #388E3C
        static let sapoGreenLight = Color(red: 0.784, green: 0.902, blue: 0.788)  // #C8E6C9

        // Estados
        static let recording = Color(red: 0.957, green: 0.263, blue: 0.212)  // #F44336
        static let processing = Color(red: 1.0, green: 0.757, blue: 0.027)  // #FFC107
        static let aiPolish = Color(red: 0.173, green: 0.557, blue: 0.859)  // #2C8EDB
        static let compactMode = Color(red: 0.608, green: 0.349, blue: 0.816)  // #9B59D0
        static let error = Color(red: 1.0, green: 0.596, blue: 0.0)  // #FF9800
        static let disabled = Color(red: 0.620, green: 0.620, blue: 0.620)  // #9E9E9E

        // UI
        static let background = Color(red: 0.118, green: 0.118, blue: 0.118)  // #1E1E1E
        static let surface = Color(red: 0.176, green: 0.176, blue: 0.176)  // #2D2D2D
        static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.15)
    }

    // MARK: - Animaciones

    /// Semantic motion tokens shared across the app.
    enum Animation {
        /// Main HUD morph: active-pill swaps inside the overlay and other
        /// state-driven layout springs.
        static let morph: SwiftUI.Animation = .spring(duration: 0.35, bounce: 0.2)

        /// Detach/absorb spring for the droplet pill separating from the dock
        /// chip: slightly bouncier than `morph` so the drop reads as physical.
        static let droplet: SwiftUI.Animation = .spring(duration: 0.42, bounce: 0.3)

        /// Conditional sections revealing/collapsing (settings cards, hints).
        static let reveal: SwiftUI.Animation = .smooth(duration: 0.2)

        /// Pop half of a one-shot scale bounce; call sites pair it with their
        /// own calmer settle spring.
        static let microBounce: SwiftUI.Animation = .spring(duration: 0.14, bounce: 0.6)

        /// Rolling digits paired with `.contentTransition(.numericText())`.
        static let tick: SwiftUI.Animation = .easeOut(duration: 0.2)

        /// Continuous progress fills (audio players) bridging 0.1 s timer ticks.
        static let progress: SwiftUI.Animation = .linear(duration: 0.1)

        /// System Reduce Motion for non-View call sites (managers); views
        /// should read `@Environment(\.accessibilityReduceMotion)` instead.
        @MainActor static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: - UI Sizes

    enum Sizes {
        static let menuBarWidth: CGFloat = 320
        static let cornerRadius: CGFloat = 12
        static let smallCornerRadius: CGFloat = 8
        static let padding: CGFloat = 16
        static let smallPadding: CGFloat = 8
        static let iconSize: CGFloat = 24
        static let buttonHeight: CGFloat = 44
    }

    // MARK: - Hotkey Defaults

    enum Hotkey {
        static let defaultKeyCode: UInt32 = 49  // Space
        static let defaultModifiers: UInt32 = 2048  // Option key
        static let defaultTriggerKind = "keyCombination"
        static let defaultDoubleTapModifier: UInt32 = 2048  // Option key
    }

    // MARK: - Audio Settings

    enum Audio {
        static let sampleRate: Double = 16000
        static let channels: UInt32 = 1
        static let bufferSize: UInt32 = 4096
    }

    // MARK: - Storage Keys

    enum StorageKeys {
        static let autoPaste = "autoPaste"
        static let playSound = "playSound"
        static let soundVolume = "soundVolume"  // Volumen de 0.0 a 1.0
        static let appLanguage = "appLanguage"
        static let language = "language"
        static let onboardingComplete = "onboardingComplete"
        /// cdhash of the build that last wrote the keychain item, to re-own it after rebuilds
        static let keychainOwnerCodeHash = "keychainOwnerCodeHash"
        /// Which keychain keys hold a value (names only, never secrets), so
        /// launch/settings "is X configured" checks skip the keychain prompt
        static let keychainStoredKeyHints = "keychainStoredKeyHints"
        static let hotkeyTriggerKind = "hotkeyTriggerKind"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyDoubleTapModifier = "hotkeyDoubleTapModifier"
        static let selectedMicrophone = "selectedMicrophone"
        /// Pin the explicit mic selection as the system default input (defaults
        /// to true): device swaps (AirPods connecting) never steal the mic, and
        /// captures always open the already-warm default route.
        static let pinPrimaryMicrophone = "pinPrimaryMicrophone"

        // Motor de transcripcion
        static let transcriptionEngine = "transcriptionEngine"
        static let whisperKitModel = "whisperKitModel"
        /// R4: minutes of idle before the local model is unloaded (0 = keep loaded).
        static let whisperKitUnloadAfterMinutes = "whisperKitUnloadAfterMinutes"
        static let localAIServerBaseURL = "localAIServerBaseURL"
        static let localAIServerModel = "localAIServerModel"

        // AI polish
        static let aiPolishEnabled = "aiPolishEnabled"
        static let aiPolishMode = "aiPolishMode"
        static let aiPolishOutputLanguage = "aiPolishOutputLanguage"
        /// Last explicit translation target, restored by the overlay translation chip.
        static let aiPolishQuickTranslationTarget = "aiPolishQuickTranslationTarget"
        static let aiPolishEndpoint = "aiPolishEndpoint"
        static let aiPolishCustomBaseURL = "aiPolishCustomBaseURL"
        static let aiPolishModel = "aiPolishModel"
        static let aiPolishReasoningEffort = "aiPolishReasoningEffort"
        static let aiPolishEndpointModelPrefix = "aiPolishModel."
        static let aiPolishEndpointBaseURLPrefix = "aiPolishBaseURL."
        static let aiPolishEndpointRecentModelsPrefix = "aiPolishRecentModels."

        // Deepgram
        /// Legacy plaintext location, kept only so the launch migration can
        /// move the value into the Keychain. Read keys via KeychainStore.
        static let deepgramAPIKey = "deepgramAPIKey"
        static let deepgramTranscriptionMode = "deepgramTranscriptionMode"

        // ElevenLabs
        /// Legacy plaintext location, kept only so the launch migration can
        /// move the value into the Keychain. Read keys via KeychainStore.
        static let elevenLabsAPIKey = "elevenLabsAPIKey"
        static let elevenLabsTranscriptionMode = "elevenLabsTranscriptionMode"

        // Audio
        static let audioGain = "audioGain"
        static let audioUploadQuality = "audioUploadQuality"

        // Overlay
        static let overlayPosition = "overlayPosition"

        // History retention (H6)
        static let historyAudioMaxMB = "historyAudioMaxMB"
        static let historyAutoDeleteDays = "historyAutoDeleteDays"  // 0 = never

        // Auto-Ducking
        static let autoDuckingEnabled = "autoDuckingEnabled"
        static let autoDuckingAmount = "autoDuckingAmount"  // 0.0 a 1.0 (porcentaje de reducción)
    }
}

// MARK: - Color Extensions

extension Color {
    static let sapoGreen = Constants.Colors.sapoGreen
    static let sapoGreenDark = Constants.Colors.sapoGreenDark
    static let sapoGreenLight = Constants.Colors.sapoGreenLight
    static let recording = Constants.Colors.recording
    static let processing = Constants.Colors.processing
    static let aiPolish = Constants.Colors.aiPolish
    static let compactMode = Constants.Colors.compactMode
    static let sapoError = Constants.Colors.error
    static let disabled = Constants.Colors.disabled
}
