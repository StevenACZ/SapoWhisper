//
//  AudioUploadQuality.swift
//  SapoWhisper
//

import AVFoundation

nonisolated enum AudioUploadQuality: String, CaseIterable, Identifiable, Codable {
    case ultraFast = "ultra_fast"
    case medium
    case high
    case ultraOriginal = "ultra_original"

    static let defaultValue: AudioUploadQuality = .medium

    var id: String { rawValue }

    static func stored(in defaults: UserDefaults = .standard) -> AudioUploadQuality {
        guard let rawValue = defaults.string(forKey: Constants.StorageKeys.audioUploadQuality) else {
            return defaultValue
        }
        return AudioUploadQuality(rawValue: rawValue) ?? defaultValue
    }

    var displayName: String {
        switch self {
        case .ultraFast:
            return "audio_upload_quality.ultra_fast".localized
        case .medium:
            return "audio_upload_quality.medium".localized
        case .high:
            return "audio_upload_quality.high".localized
        case .ultraOriginal:
            return "audio_upload_quality.ultra_original".localized
        }
    }

    var detail: String {
        switch self {
        case .ultraFast:
            return "audio_upload_quality.ultra_fast_detail".localized
        case .medium:
            return "audio_upload_quality.medium_detail".localized
        case .high:
            return "audio_upload_quality.high_detail".localized
        case .ultraOriginal:
            return "audio_upload_quality.ultra_original_detail".localized
        }
    }

    var preservesOriginalEncoding: Bool {
        self == .ultraOriginal
    }

    func audioFormat(matching inputFormat: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate(matching: inputFormat),
            channels: 1,
            interleaved: false
        )!
    }

    /// Batch capture format for a concrete target engine. Whisper-family
    /// engines decode at 16 kHz mono, so for the STT-oriented qualities
    /// (ultraFast, medium) the capture goes straight to 16 kHz instead of
    /// recording 24 kHz only for the model to resample again. High and
    /// ultraOriginal keep the user's explicit fidelity choice — history WAVs
    /// can be retranscribed later with a cloud engine.
    func audioFormat(matching inputFormat: AVAudioFormat, for engine: TranscriptionEngine?) -> AVAudioFormat {
        if engine?.isWhisperFamily == true, self == .ultraFast || self == .medium {
            return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        }
        return audioFormat(matching: inputFormat)
    }

    private var commonFormat: AVAudioCommonFormat {
        switch self {
        case .ultraFast, .medium, .high:
            return .pcmFormatInt16
        case .ultraOriginal:
            return .pcmFormatFloat32
        }
    }

    private func sampleRate(matching inputFormat: AVAudioFormat) -> Double {
        switch self {
        case .ultraFast:
            return 16_000
        case .medium:
            return 24_000
        case .high:
            return min(validInputSampleRate(inputFormat), 48_000)
        case .ultraOriginal:
            return validInputSampleRate(inputFormat)
        }
    }

    private func validInputSampleRate(_ inputFormat: AVAudioFormat) -> Double {
        inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48_000
    }
}
