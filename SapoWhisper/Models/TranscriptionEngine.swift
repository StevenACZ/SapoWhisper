//
//  TranscriptionEngine.swift
//  SapoWhisper
//
//

import Foundation

/// Motor de transcripción disponible
enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case appleOnline = "apple"
    case whisperLocal = "whisper"
    case googleCloud = "google"
    case deepgram = "deepgram"
    case geminiAudio = "gemini_audio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnline:
            return "Apple (Online)"
        case .whisperLocal:
            return "Whisper (Local)"
        case .googleCloud:
            return "Google Cloud"
        case .deepgram:
            return "Deepgram"
        case .geminiAudio:
            return "Gemini Audio"
        }
    }

    var description: String {
        switch self {
        case .appleOnline:
            return "engine.apple.description".localized
        case .whisperLocal:
            return "engine.whisper.description".localized
        case .googleCloud:
            return "engine.google.description".localized
        case .deepgram:
            return "engine.deepgram.description".localized
        case .geminiAudio:
            return "engine.gemini_audio.description".localized
        }
    }

    var icon: String {
        switch self {
        case .appleOnline:
            return "icloud"
        case .whisperLocal:
            return "desktopcomputer"
        case .googleCloud:
            return "cloud"
        case .deepgram:
            return "waveform.badge.mic"
        case .geminiAudio:
            return "sparkles"
        }
    }

    var requiresInternet: Bool {
        switch self {
        case .whisperLocal:
            return false
        case .appleOnline, .googleCloud, .deepgram, .geminiAudio:
            return true
        }
    }
}

enum GeminiAudioModel: String, CaseIterable, Identifiable {
    case gemini31ProPreview = "gemini-3.1-pro-preview"
    case gemini3FlashPreview = "gemini-3-flash-preview"
    case gemini25Flash = "gemini-2.5-flash"
    case gemini31FlashLite = "gemini-3.1-flash-lite"
    case gemini25FlashLite = "gemini-2.5-flash-lite"

    static let defaultModel: GeminiAudioModel = .gemini31FlashLite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini31ProPreview:
            return "Gemini 3.1 Pro Preview"
        case .gemini3FlashPreview:
            return "Gemini 3 Flash Preview"
        case .gemini25Flash:
            return "Gemini 2.5 Flash"
        case .gemini31FlashLite:
            return "Gemini 3.1 Flash-Lite"
        case .gemini25FlashLite:
            return "Gemini 2.5 Flash-Lite"
        }
    }

    var description: String {
        switch self {
        case .gemini31ProPreview:
            return "gemini.audio.model_31_pro_desc".localized
        case .gemini3FlashPreview:
            return "gemini.audio.model_3_flash_desc".localized
        case .gemini25Flash:
            return "gemini.audio.model_25_flash_desc".localized
        case .gemini31FlashLite:
            return "gemini.audio.model_31_lite_desc".localized
        case .gemini25FlashLite:
            return "gemini.audio.model_25_lite_desc".localized
        }
    }

    var approximateFourMinuteCost: String {
        switch self {
        case .gemini31ProPreview:
            return "~$0.027"
        case .gemini3FlashPreview:
            return "~$0.011"
        case .gemini25Flash:
            return "~$0.010"
        case .gemini31FlashLite:
            return "~$0.005"
        case .gemini25FlashLite:
            return "~$0.003"
        }
    }

    var isRecommended: Bool {
        self == Self.defaultModel
    }
}

/// Modelos de WhisperKit optimizados para Apple Silicon
enum WhisperKitModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largev3 = "openai_whisper-large-v3"
    case largev3Turbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largev3: return "Large V3"
        case .largev3Turbo: return "Large V3 Turbo"
        }
    }

    var fileSize: String {
        switch self {
        case .tiny: return "76.6 MB"
        case .base: return "146.7 MB"
        case .small: return "486.5 MB"
        case .largev3: return "3.09 GB"
        case .largev3Turbo: return "3.2 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .tiny: return Int64(76.6 * 1024 * 1024)
        case .base: return Int64(146.7 * 1024 * 1024)
        case .small: return Int64(486.5 * 1024 * 1024)
        case .largev3: return Int64(3.09 * 1024 * 1024 * 1024)
        case .largev3Turbo: return Int64(3.2 * 1024 * 1024 * 1024)
        }
    }

    var speed: String {
        switch self {
        case .tiny: return "model.speed.very_fast".localized
        case .base: return "model.speed.fast".localized
        case .small: return "model.speed.moderate".localized
        case .largev3: return "model.speed.slow".localized
        case .largev3Turbo: return "model.speed.fast".localized
        }
    }

    var accuracy: Int {
        switch self {
        case .tiny: return 2
        case .base: return 3
        case .small: return 4
        case .largev3: return 5
        case .largev3Turbo: return 5
        }
    }

    var isRecommended: Bool {
        self == .small || self == .largev3Turbo
    }

    var recommendedFor: String {
        switch self {
        case .tiny: return "Pruebas rapidas"
        case .base: return "Uso diario basico"
        case .small: return "Mejor balance"
        case .largev3: return "Maxima precision"
        case .largev3Turbo: return "Precision + Velocidad"
        }
    }
}
