//
//  TranscriptionEngineVariant.swift
//  SapoWhisper
//

import Foundation

/// One concrete way to transcribe: a `TranscriptionEngine` plus the mode it
/// runs in.
///
/// `TranscriptionEngine` is the brand the user picks as the primary; a variant
/// is what actually runs. They differ because a live mode is a different
/// runtime path (WebSocket dictation) rather than a setting of its brand, and
/// the backup engine must be selectable and executable at that granularity.
nonisolated enum TranscriptionEngineVariant: String, CaseIterable, Identifiable {
    case mlxWhisper = "mlx_whisper"
    case localAIServer = "local_ai_server"
    case deepgramNova3 = "deepgram_nova3"
    case deepgramFluxLive = "deepgram_flux_live"
    case elevenLabsScribeBatch = "elevenlabs_scribe_batch"
    case elevenLabsScribeRealtime = "elevenlabs_scribe_realtime"

    var id: String { rawValue }

    var engine: TranscriptionEngine {
        switch self {
        case .mlxWhisper:
            return .mlxWhisper
        case .localAIServer:
            return .localAIServer
        case .deepgramNova3, .deepgramFluxLive:
            return .deepgram
        case .elevenLabsScribeBatch, .elevenLabsScribeRealtime:
            return .elevenLabsScribe
        }
    }

    /// Dictates through a live WebSocket session instead of uploading a
    /// finished file. Streaming variants only run natively when they own the
    /// dictation from the start; rescuing an already-captured WAV goes through
    /// `fileTranscriptionVariant`.
    var isStreaming: Bool {
        switch self {
        case .deepgramFluxLive, .elevenLabsScribeRealtime:
            return true
        case .mlxWhisper, .localAIServer, .deepgramNova3, .elevenLabsScribeBatch:
            return false
        }
    }

    /// The variant that transcribes an existing recording for this provider.
    /// Used for History requests and normalization of legacy realtime backups.
    var fileTranscriptionVariant: TranscriptionEngineVariant {
        switch self {
        case .deepgramFluxLive:
            return .deepgramNova3
        case .elevenLabsScribeRealtime:
            return .elevenLabsScribeBatch
        case .mlxWhisper, .localAIServer, .deepgramNova3, .elevenLabsScribeBatch:
            return self
        }
    }

    static var backupCandidates: [Self] { allCases.filter { !$0.isStreaming } }

    var requiresInternet: Bool { engine.requiresInternet }

    /// Brand + model wording, matching what History already records so a row
    /// and the picker never disagree about which engine ran.
    var displayName: String {
        switch self {
        case .mlxWhisper, .localAIServer:
            return engine.displayName
        case .deepgramNova3:
            return DeepgramTranscriptionMode.nova3.historyName
        case .deepgramFluxLive:
            return DeepgramTranscriptionMode.fluxLive.historyName
        case .elevenLabsScribeBatch:
            return ElevenLabsTranscriptionMode.scribeV2Batch.historyName
        case .elevenLabsScribeRealtime:
            return ElevenLabsTranscriptionMode.scribeV2Realtime.historyName
        }
    }

    var icon: String {
        switch self {
        case .mlxWhisper, .localAIServer:
            return engine.icon
        case .deepgramNova3:
            return DeepgramTranscriptionMode.nova3.icon
        case .deepgramFluxLive:
            return DeepgramTranscriptionMode.fluxLive.icon
        case .elevenLabsScribeBatch:
            return ElevenLabsTranscriptionMode.scribeV2Batch.icon
        case .elevenLabsScribeRealtime:
            return ElevenLabsTranscriptionMode.scribeV2Realtime.icon
        }
    }

    var deepgramMode: DeepgramTranscriptionMode? {
        switch self {
        case .deepgramNova3:
            return .nova3
        case .deepgramFluxLive:
            return .fluxLive
        default:
            return nil
        }
    }

    var elevenLabsMode: ElevenLabsTranscriptionMode? {
        switch self {
        case .elevenLabsScribeBatch:
            return .scribeV2Batch
        case .elevenLabsScribeRealtime:
            return .scribeV2Realtime
        default:
            return nil
        }
    }

    /// The variant the current primary selection resolves to.
    static func primary(
        engine: TranscriptionEngine,
        deepgramMode: DeepgramTranscriptionMode,
        elevenLabsMode: ElevenLabsTranscriptionMode
    ) -> TranscriptionEngineVariant {
        switch engine {
        case .mlxWhisper:
            return .mlxWhisper
        case .localAIServer:
            return .localAIServer
        case .deepgram:
            return deepgramMode == .fluxLive ? .deepgramFluxLive : .deepgramNova3
        case .elevenLabsScribe:
            return elevenLabsMode == .scribeV2Realtime ? .elevenLabsScribeRealtime : .elevenLabsScribeBatch
        }
    }

    /// The file-transcription variant of a brand, for callers that only know
    /// the engine (the History retranscribe menu picks a brand, not a mode).
    static func fileVariant(for engine: TranscriptionEngine) -> TranscriptionEngineVariant {
        switch engine {
        case .mlxWhisper:
            return .mlxWhisper
        case .localAIServer:
            return .localAIServer
        case .deepgram:
            return .deepgramNova3
        case .elevenLabsScribe:
            return .elevenLabsScribeBatch
        }
    }

    /// Resolves a stored backup selection to its file mode. Values written while the picker
    /// still stored plain engines ("deepgram", "elevenlabs_scribe") map to that
    /// brand's file variant — which is the only thing the old picker ever ran.
    static func stored(_ rawValue: String) -> TranscriptionEngineVariant? {
        if let variant = TranscriptionEngineVariant(rawValue: rawValue) {
            return variant.fileTranscriptionVariant
        }
        switch TranscriptionEngine(rawValue: rawValue) {
        case .mlxWhisper:
            return .mlxWhisper
        case .localAIServer:
            return .localAIServer
        case .deepgram:
            return .deepgramNova3
        case .elevenLabsScribe:
            return .elevenLabsScribeBatch
        case nil:
            return nil
        }
    }
}
