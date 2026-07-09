//
//  MLXWhisperRuntime.swift
//  MLXWhisper
//

import Foundation
import MLX

/// Small runtime surface so the app never needs to import MLX directly.
public enum MLXWhisperRuntime {
    /// Return the Metal buffer pool to the OS after an unload — dropping the
    /// model frees its arrays, but MLX keeps recycled buffers cached
    /// otherwise (~hundreds of MB resident).
    public static func clearMemoryCache() {
        Memory.clearCache()
    }
}

extension WhisperModel {
    /// Convenience entry point over raw 16 kHz mono samples, so callers do
    /// not need to import MLX to build an `MLXArray`. Cancellation-aware:
    /// throws `CancellationError` when the surrounding task is cancelled.
    public func generate(
        samples: [Float],
        generationParameters: STTGenerateParameters
    ) throws -> STTOutput {
        try generateCancellable(audio: MLXArray(samples), generationParameters: generationParameters)
    }
}
