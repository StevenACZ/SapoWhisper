//
//  TranscriptionEngine.swift
//  SapoWhisper
//
//

import Foundation

/// Motor de transcripción disponible
nonisolated enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case whisperLocal = "whisper"
    case localAIServer = "local_ai_server"
    case deepgram = "deepgram"
    case elevenLabsScribe = "elevenlabs_scribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperLocal:
            return "Whisper (Local)"
        case .localAIServer:
            return "Local AI Server (NVIDIA)"
        case .deepgram:
            return "Deepgram"
        case .elevenLabsScribe:
            return "ElevenLabs Scribe v2"
        }
    }

    /// Localized copy is UI-only; localization lookups stay on the main actor.
    @MainActor var description: String {
        switch self {
        case .whisperLocal:
            return "engine.whisper.description".localized
        case .localAIServer:
            return "engine.local_ai_server.description".localized
        case .deepgram:
            return "engine.deepgram.description".localized
        case .elevenLabsScribe:
            return "engine.elevenlabs_scribe.description".localized
        }
    }

    var icon: String {
        switch self {
        case .whisperLocal:
            return "desktopcomputer"
        case .localAIServer:
            return "server.rack"
        case .deepgram:
            return "waveform.badge.mic"
        case .elevenLabsScribe:
            return "waveform.badge.magnifyingglass"
        }
    }

    var requiresInternet: Bool {
        switch self {
        case .whisperLocal, .localAIServer:
            return false
        case .deepgram, .elevenLabsScribe:
            return true
        }
    }

    /// Engine surfaced as the recommended high-accuracy option in the picker.
    var isRecommended: Bool {
        self == .elevenLabsScribe
    }

    /// Engines whose decoder consumes 16 kHz mono natively (Whisper running
    /// locally via WhisperKit or on the Local AI Server). Capturing above
    /// 16 kHz for them only adds a second resample before decoding.
    var isWhisperFamily: Bool {
        switch self {
        case .whisperLocal, .localAIServer:
            return true
        case .deepgram, .elevenLabsScribe:
            return false
        }
    }
}

/// Modelos de WhisperKit optimizados para Apple Silicon
enum WhisperKitModel: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case largev3V20240930Quantized = "openai_whisper-large-v3-v20240930_626MB"
    case largev3V20240930 = "openai_whisper-large-v3-v20240930"
    case largev3 = "openai_whisper-large-v3"
    case largev3Turbo = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .largev3V20240930Quantized: return "Large V3 Turbo (Comprimido)"
        case .largev3V20240930: return "Large V3 Turbo (Oficial)"
        case .largev3: return "Large V3"
        case .largev3Turbo: return "Large V3 Turbo"
        }
    }

    var fileSize: String {
        switch self {
        case .tiny: return "76.6 MB"
        case .base: return "146.7 MB"
        case .small: return "486.5 MB"
        case .largev3V20240930Quantized: return "626 MB"
        case .largev3V20240930: return "1.5 GB"
        case .largev3: return "3.09 GB"
        case .largev3Turbo: return "3.2 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .tiny: return Int64(76.6 * 1024 * 1024)
        case .base: return Int64(146.7 * 1024 * 1024)
        case .small: return Int64(486.5 * 1024 * 1024)
        case .largev3V20240930Quantized: return Int64(626 * 1024 * 1024)
        case .largev3V20240930: return Int64(1.5 * 1024 * 1024 * 1024)
        case .largev3: return Int64(3.09 * 1024 * 1024 * 1024)
        case .largev3Turbo: return Int64(3.2 * 1024 * 1024 * 1024)
        }
    }

    var speed: String {
        switch self {
        case .tiny: return "model.speed.very_fast".localized
        case .base: return "model.speed.fast".localized
        case .small: return "model.speed.moderate".localized
        case .largev3V20240930Quantized: return "model.speed.fast".localized
        case .largev3V20240930: return "model.speed.fast".localized
        case .largev3: return "model.speed.slow".localized
        case .largev3Turbo: return "model.speed.fast".localized
        }
    }

    var accuracy: Int {
        switch self {
        case .tiny: return 2
        case .base: return 3
        case .small: return 4
        case .largev3V20240930Quantized: return 4
        case .largev3V20240930: return 5
        case .largev3: return 5
        case .largev3Turbo: return 5
        }
    }

    var isRecommended: Bool {
        self == .small || self == .largev3V20240930
    }

    var recommendedFor: String {
        switch self {
        case .tiny: return "Pruebas rapidas"
        case .base: return "Uso diario basico"
        case .small: return "Mejor balance"
        case .largev3V20240930Quantized: return "Turbo oficial comprimido"
        case .largev3V20240930: return "Turbo oficial de OpenAI"
        case .largev3: return "Maxima precision"
        case .largev3Turbo: return "Precision + Velocidad"
        }
    }
}
