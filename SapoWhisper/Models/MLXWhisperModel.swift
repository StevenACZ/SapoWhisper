//
//  MLXWhisperModel.swift
//  SapoWhisper
//

import SwiftUI

/// Curated MLX Whisper tiers (mlx-community checkpoints; the vendored loader
/// reads fp16 and 8-bit quantized safetensors). Raw value = Hugging Face
/// repo ID.
nonisolated enum MLXWhisperModel: String, CaseIterable, Identifiable {
    case largeV3TurboQ8 = "mlx-community/whisper-large-v3-turbo-8bit"
    case largeV3Turbo = "mlx-community/whisper-large-v3-turbo"

    var id: String { rawValue }

    static let defaultModel: MLXWhisperModel = .largeV3TurboQ8

    /// Retired tiers and the tier that replaces each one: Base and Small missed
    /// far more words than Turbo, the 4-bit Turbo lost technical terms without
    /// being faster than the 8-bit tier, and Large V3 ran several times slower.
    static let retiredReplacements: [String: MLXWhisperModel] = [
        "mlx-community/whisper-base-fp16": .largeV3TurboQ8,
        "mlx-community/whisper-small-fp16": .largeV3TurboQ8,
        "mlx-community/whisper-large-v3-turbo-4bit": .largeV3TurboQ8,
        "mlx-community/whisper-large-v3-fp16": .largeV3Turbo,
    ]

    /// A stored or imported selection, following a retired tier to its
    /// replacement.
    init?(storedValue: String) {
        guard let model = MLXWhisperModel(rawValue: storedValue) ?? Self.retiredReplacements[storedValue] else {
            return nil
        }
        self = model
    }

    /// Pinned Hugging Face revision (commit shas resolved 2026-07-09; 8-bit tier
    /// 2026-10-18) so a moved or compromised `main` can never change what the
    /// app downloads.
    var revision: String {
        switch self {
        case .largeV3TurboQ8: return "62103fc276a35fdc76e318f314d8ff47987fba89"
        case .largeV3Turbo: return "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
        }
    }

    var displayName: String {
        switch self {
        case .largeV3TurboQ8: return "Large V3 Turbo (8-bit)"
        case .largeV3Turbo: return "Large V3 Turbo"
        }
    }

    /// Download size (weights + config + tokenizer assets), measured on the
    /// Hugging Face repos 2026-07-05 (8-bit tier 2026-10-18). Shown until the
    /// real on-disk size exists.
    var fileSize: String {
        switch self {
        case .largeV3TurboQ8: return "828 MB"
        case .largeV3Turbo: return "1.54 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .largeV3TurboQ8: return Int64(828 * 1024 * 1024)
        case .largeV3Turbo: return Int64(1.54 * 1024 * 1024 * 1024)
        }
    }

    var accuracy: Int { 5 }

    var isRecommended: Bool {
        self == Self.defaultModel
    }
}

extension MLXWhisperModel {
    @MainActor var speed: String {
        switch self {
        case .largeV3TurboQ8: return "model.speed.very_fast".localized
        case .largeV3Turbo: return "model.speed.fast".localized
        }
    }

    @MainActor var badgeText: String {
        switch self {
        case .largeV3TurboQ8: return "model.tier_recommended".localized
        case .largeV3Turbo: return "model.tier_max_precision".localized
        }
    }

    var badgeColor: Color {
        switch self {
        case .largeV3TurboQ8: return .sapoGreen
        case .largeV3Turbo: return .teal
        }
    }
}
