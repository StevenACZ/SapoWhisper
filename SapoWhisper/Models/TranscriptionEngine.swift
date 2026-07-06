//
//  TranscriptionEngine.swift
//  SapoWhisper
//
//

import Foundation

/// Motor de transcripción disponible
nonisolated enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case mlxWhisper = "mlx_whisper"
    case localAIServer = "local_ai_server"
    case deepgram = "deepgram"
    case elevenLabsScribe = "elevenlabs_scribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mlxWhisper:
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
        case .mlxWhisper:
            return "engine.mlx_whisper.description".localized
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
        case .mlxWhisper:
            return "bolt.circle"
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
        case .mlxWhisper, .localAIServer:
            return false
        case .deepgram, .elevenLabsScribe:
            return true
        }
    }

    /// Engine surfaced as the recommended option in the picker: MLX runs the
    /// same Whisper turbo weights fully on-device at GPU speed (benched
    /// 2026-07-05: ~6x faster than the removed WhisperKit engine, equal
    /// quality).
    var isRecommended: Bool {
        self == .mlxWhisper
    }

    /// Engines whose decoder consumes 16 kHz mono natively (Whisper running
    /// locally via MLX or on the Local AI Server). Capturing above 16 kHz
    /// for them only adds a second resample before decoding.
    var isWhisperFamily: Bool {
        switch self {
        case .mlxWhisper, .localAIServer:
            return true
        case .deepgram, .elevenLabsScribe:
            return false
        }
    }
}
