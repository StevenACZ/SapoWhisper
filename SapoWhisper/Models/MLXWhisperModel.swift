//
//  MLXWhisperModel.swift
//  SapoWhisper
//

import SwiftUI

/// Curated MLX Whisper tiers (mlx-community checkpoints; the vendored loader
/// reads fp16 and 4/8-bit quantized safetensors). Raw value = Hugging Face
/// repo ID.
nonisolated enum MLXWhisperModel: String, CaseIterable, Identifiable {
    case base = "mlx-community/whisper-base-fp16"
    case small = "mlx-community/whisper-small-fp16"
    case largeV3TurboQ4 = "mlx-community/whisper-large-v3-turbo-4bit"
    case largeV3Turbo = "mlx-community/whisper-large-v3-turbo"
    case largeV3 = "mlx-community/whisper-large-v3-fp16"

    var id: String { rawValue }

    /// Pinned Hugging Face revision (commit shas resolved 2026-07-09) so a
    /// moved or compromised `main` can never change what the app downloads.
    var revision: String {
        switch self {
        case .base: return "3623ea5c2566e1320ba8eef401ec6c9cf58c6a2f"
        case .small: return "fa19eb05939653a9334d81bec7e053db81970170"
        case .largeV3TurboQ4: return "0f058d38170d183f9fdee07908f5b515d91793a8"
        case .largeV3Turbo: return "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
        case .largeV3: return "5467ef1f82cf0e110f521092acb434d9c82b5d5a"
        }
    }

    var displayName: String {
        switch self {
        case .base: return "Base"
        case .small: return "Small"
        case .largeV3TurboQ4: return "Large V3 Turbo (4-bit)"
        case .largeV3Turbo: return "Large V3 Turbo"
        case .largeV3: return "Large V3"
        }
    }

    /// Download size (weights + config + tokenizer assets), measured on the
    /// Hugging Face repos 2026-07-05 (4-bit tier 2026-07-09). Shown until the
    /// real on-disk size exists.
    var fileSize: String {
        switch self {
        case .base: return "141 MB"
        case .small: return "463 MB"
        case .largeV3TurboQ4: return "464 MB"
        case .largeV3Turbo: return "1.54 GB"
        case .largeV3: return "2.95 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .base: return Int64(141 * 1024 * 1024)
        case .small: return Int64(463 * 1024 * 1024)
        case .largeV3TurboQ4: return Int64(464 * 1024 * 1024)
        case .largeV3Turbo: return Int64(1.54 * 1024 * 1024 * 1024)
        case .largeV3: return Int64(2.95 * 1024 * 1024 * 1024)
        }
    }

    /// 1...5 stars in the model picker.
    var accuracy: Int {
        switch self {
        case .base: return 3
        case .small: return 4
        case .largeV3TurboQ4: return 5
        case .largeV3Turbo: return 5
        case .largeV3: return 5
        }
    }

    var isRecommended: Bool {
        self == .largeV3Turbo
    }
}

extension MLXWhisperModel {
    @MainActor var speed: String {
        switch self {
        case .base: return "model.speed.very_fast".localized
        case .small: return "model.speed.fast".localized
        case .largeV3TurboQ4: return "model.speed.fast".localized
        case .largeV3Turbo: return "model.speed.fast".localized
        case .largeV3: return "model.speed.moderate".localized
        }
    }

    @MainActor var badgeText: String { "badge.recommended".localized }
    var badgeColor: Color { .sapoGreen }
}
