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

    /// Caps the freed buffers MLX keeps for reuse. Beam search grows its KV
    /// caches every step, so each step frees a new size and the unbounded
    /// pool reached 12 GB resident after a day of dictation.
    public static func limitMemoryCache(bytes: Int) {
        Memory.cacheLimit = bytes
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
