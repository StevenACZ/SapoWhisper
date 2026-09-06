//
//  STTTypes.swift
//  MLXWhisper
//
//  Vendored from mlx-audio-swift (MIT, see LICENSE-mlx-audio-swift) at commit
//  580e952, trimmed to the types the Whisper model uses. Local change:
//  `STTGenerateParameters.initialPrompt` feeds the decoder a
//  `<|startofprev|>` prefix (vocabulary / domain hint).
//

import Foundation

public struct STTGenerateParameters: Sendable {
    public let maxTokens: Int
    public let temperature: Float
    public let topP: Float
    public let topK: Int
    public let verbose: Bool
    public let language: String?
    public let chunkDuration: Float
    public let minChunkDuration: Float
    public let repetitionPenalty: Float
    public let repetitionContextSize: Int
    /// Plain-text hint tokenized and prepended as `<|startofprev|>` context —
    /// Whisper's initial prompt. Biases spelling toward the supplied terms
    /// without being part of the transcription output.
    public let initialPrompt: String?

    public init(
        maxTokens: Int = 8192,
        temperature: Float = 0.0,
        topP: Float = 0.95,
        topK: Int = 0,
        verbose: Bool = false,
        language: String? = nil,
        chunkDuration: Float = 1200.0,
        minChunkDuration: Float = 1.0,
        repetitionPenalty: Float = 1.0,
        repetitionContextSize: Int = 32,
        initialPrompt: String? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.verbose = verbose
        self.language = language
        self.chunkDuration = chunkDuration
        self.minChunkDuration = minChunkDuration
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.initialPrompt = initialPrompt
    }
}

/// Events emitted during speech-to-text streaming generation.
public enum STTGeneration: Sendable {
    /// Accepted text delta; incomplete decoder attempts are never published.
    case token(String)
    /// Final transcription result
    case result(STTOutput)
}

/// Output from speech-to-text transcription.
public struct STTOutput: @unchecked Sendable {
    /// The transcribed text.
    public let text: String
    /// Transcription segments with timing information (optional).
    public let segments: [[String: Any]]?
    /// Detected language (optional).
    public let language: String?
    /// Number of tokens in the prompt.
    public let promptTokens: Int
    /// Number of tokens generated.
    public let generationTokens: Int
    /// Total number of tokens processed.
    public let totalTokens: Int
    public let decodingRetries: Int
    /// Prompt processing tokens per second.
    public let promptTps: Double
    /// Generation tokens per second.
    public let generationTps: Double
    /// Total processing time in seconds.
    public let totalTime: Double
    /// Peak memory usage in GB.
    public let peakMemoryUsage: Double

    public init(
        text: String,
        segments: [[String: Any]]? = nil,
        language: String? = nil,
        promptTokens: Int = 0,
        generationTokens: Int = 0,
        totalTokens: Int = 0,
        decodingRetries: Int = 0,
        promptTps: Double = 0.0,
        generationTps: Double = 0.0,
        totalTime: Double = 0.0,
        peakMemoryUsage: Double = 0.0
    ) {
        self.text = text
        self.segments = segments
        self.language = language
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.totalTokens = totalTokens
        self.decodingRetries = decodingRetries
        self.promptTps = promptTps
        self.generationTps = generationTps
        self.totalTime = totalTime
        self.peakMemoryUsage = peakMemoryUsage
    }
}
