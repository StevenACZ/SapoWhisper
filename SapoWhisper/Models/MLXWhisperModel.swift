//
//  MLXWhisperModel.swift
//  SapoWhisper
//

import SwiftUI

/// Shared descriptor so `WhisperModelButton` renders WhisperKit and MLX
/// model options with one implementation.
protocol LocalWhisperModelInfo {
    var displayName: String { get }
    var fileSize: String { get }
    var speed: String { get }
    var accuracy: Int { get }
    var isRecommended: Bool { get }
    /// Badge shown next to recommended models (localized).
    var badgeText: String { get }
    var badgeColor: Color { get }
}

/// Curated MLX Whisper tiers (mlx-community fp16 checkpoints — the vendored
/// loader reads plain safetensors only, so quantized 4/8-bit variants are
/// deliberately not offered). Raw value = Hugging Face repo ID.
nonisolated enum MLXWhisperModel: String, CaseIterable, Identifiable {
    case base = "mlx-community/whisper-base-fp16"
    case small = "mlx-community/whisper-small-fp16"
    case largeV3Turbo = "mlx-community/whisper-large-v3-turbo"
    case largeV3 = "mlx-community/whisper-large-v3-fp16"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .base: return "Base"
        case .small: return "Small"
        case .largeV3Turbo: return "Large V3 Turbo"
        case .largeV3: return "Large V3"
        }
    }

    /// Download size (weights + config + tokenizer assets), measured on the
    /// Hugging Face repos 2026-07-05.
    var fileSize: String {
        switch self {
        case .base: return "141 MB"
        case .small: return "463 MB"
        case .largeV3Turbo: return "1.54 GB"
        case .largeV3: return "2.95 GB"
        }
    }

    var sizeInBytes: Int64 {
        switch self {
        case .base: return Int64(141 * 1024 * 1024)
        case .small: return Int64(463 * 1024 * 1024)
        case .largeV3Turbo: return Int64(1.54 * 1024 * 1024 * 1024)
        case .largeV3: return Int64(2.95 * 1024 * 1024 * 1024)
        }
    }

    var accuracy: Int {
        switch self {
        case .base: return 3
        case .small: return 4
        case .largeV3Turbo: return 5
        case .largeV3: return 5
        }
    }

    var isRecommended: Bool {
        self == .largeV3Turbo
    }
}

extension MLXWhisperModel: LocalWhisperModelInfo {
    var speed: String {
        switch self {
        case .base: return "model.speed.very_fast".localized
        case .small: return "model.speed.fast".localized
        case .largeV3Turbo: return "model.speed.fast".localized
        case .largeV3: return "model.speed.moderate".localized
        }
    }

    var badgeText: String { "badge.pro".localized }
    var badgeColor: Color { .purple }
}

extension WhisperKitModel: LocalWhisperModelInfo {
    var badgeText: String {
        self == .small ? "badge.balance".localized : "badge.pro".localized
    }

    var badgeColor: Color {
        self == .small ? .blue : .purple
    }
}
