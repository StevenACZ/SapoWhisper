//
//  ElevenLabsTranscriptionMode.swift
//  SapoWhisper
//

import Foundation

enum ElevenLabsTranscriptionMode: String, CaseIterable, Identifiable {
    case scribeV2Batch = "scribe_v2_batch"
    case scribeV2Realtime = "scribe_v2_realtime"

    static let defaultMode: ElevenLabsTranscriptionMode = .scribeV2Batch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scribeV2Batch:
            return "elevenlabs.mode_batch".localized
        case .scribeV2Realtime:
            return "elevenlabs.mode_realtime".localized
        }
    }

    var description: String {
        switch self {
        case .scribeV2Batch:
            return "elevenlabs.mode_batch_desc".localized
        case .scribeV2Realtime:
            return "elevenlabs.mode_realtime_desc".localized
        }
    }

    var icon: String {
        switch self {
        case .scribeV2Batch:
            return "waveform"
        case .scribeV2Realtime:
            return "bolt.fill"
        }
    }

    var historyName: String {
        switch self {
        case .scribeV2Batch:
            return "ElevenLabs Scribe v2"
        case .scribeV2Realtime:
            return "ElevenLabs Scribe Realtime v2"
        }
    }
}
