//
//  DeepgramTranscriptionMode.swift
//  SapoWhisper
//

import Foundation

enum DeepgramTranscriptionMode: String, CaseIterable, Identifiable {
    case nova3 = "nova3"
    case fluxLive = "flux_live"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nova3:
            return "deepgram.mode_nova".localized
        case .fluxLive:
            return "deepgram.mode_flux".localized
        }
    }

    var description: String {
        switch self {
        case .nova3:
            return "deepgram.mode_nova_desc".localized
        case .fluxLive:
            return "deepgram.mode_flux_desc".localized
        }
    }

    nonisolated var icon: String {
        switch self {
        case .nova3:
            return "waveform"
        case .fluxLive:
            return "bolt.fill"
        }
    }

    nonisolated var historyName: String {
        switch self {
        case .nova3:
            return "Deepgram Nova-3"
        case .fluxLive:
            return "Deepgram Flux Live"
        }
    }
}
