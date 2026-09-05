//
//  WhisperModel.swift
//  MLXWhisper
//
//  Vendored from mlx-audio-swift (MIT, see LICENSE-mlx-audio-swift) at
//  commit 580e952. Local changes: initial-prompt (`<|startofprev|>`)
//  support wired through the decode loop, `fromPretrained`/ModelUtils
//  replaced by the app-driven `WhisperModelDownloader` (progress reporting
//  instead of prints), the STTGenerationModel protocol dropped (Whisper is
//  the only vendored model), quantized-checkpoint loading (`quantization`
//  in config.json), and Task-cancellation checks between decode steps
//  (`generateCancellable`).
//

import Foundation
import HuggingFace
import MLX
import MLXNN

public final class WhisperModel: Module {
    public let config: WhisperConfig
    public let generationConfig: WhisperGenerationConfig?

    @ModuleInfo(key: "model") var model: WhisperSubmodels

    private var tokenizer: WhisperTokenizer?

    public init(config: WhisperConfig, generationConfig: WhisperGenerationConfig? = nil) {
        self.config = config
        self.generationConfig = generationConfig
        self._model.wrappedValue = WhisperSubmodels(config: config)
    }

    public var defaultGenerationParameters: STTGenerateParameters {
        STTGenerateParameters(
            maxTokens: config.maxTargetPositions - 16,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            verbose: false,
            language: nil,
            chunkDuration: Float(WhisperAudioConfig.chunkLengthSeconds),
            minChunkDuration: 0.1,
            repetitionPenalty: 1.0,
            repetitionContextSize: 32
        )
    }

    @available(*, deprecated, message: "Use generateCancellable to preserve decoding failures.")
    public func generate(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> STTOutput {
        (try? generateCancellable(audio: audio, generationParameters: generationParameters)) ?? STTOutput(text: "")
    }

    public func generateCancellable(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) throws -> STTOutput {
        try generateOutput(audio: audio, generationParameters: generationParameters)
    }

    public func generateStream(
        audio: MLXArray,
        generationParameters: STTGenerateParameters
    ) -> AsyncThrowingStream<STTGeneration, Error> {
        AsyncThrowingStream { continuation in
            do {
                let output = try generateOutput(audio: audio, generationParameters: generationParameters) {
                    continuation.yield(.token($0))
                }
                continuation.yield(.result(output))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func generateOutput(
        audio: MLXArray,
        generationParameters: STTGenerateParameters,
        onSegment: ((String) -> Void)? = nil
    ) throws -> STTOutput {
        let startTime = Date()
        let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
        var windows = WhisperDecodingWindow.initial(sampleCount: mono.dim(0))
        let initialPromptTokens = encodeInitialPrompt(generationParameters.initialPrompt)
        var allText: [String] = []
        var allSegments: [[String: Any]] = []
        var totalPromptTokens = 0
        var totalGenerationTokens = 0
        var decodingRetries = 0
        var detectedLanguage: String?
        var detectedLanguageToken: Int?
        var index = 0

        while index < windows.count {
            try Task.checkCancellation()
            let window = windows[index]
            if generationParameters.verbose {
                print(
                    "[Whisper] window start=\(window.range.lowerBound) samples=\(window.range.count) depth=\(window.retryDepth) glossary=\(window.usesInitialPrompt && !initialPromptTokens.isEmpty)"
                )
            }
            let (text, promptTokens, generationTokens, language, languageToken, finished) = try transcribeChunk(
                audio: mono[window.range],
                generationParameters: generationParameters,
                initialPromptTokens: window.usesInitialPrompt ? initialPromptTokens : [],
                languageTokenId: detectedLanguageToken
            )
            try Task.checkCancellation()
            totalPromptTokens += promptTokens
            totalGenerationTokens += generationTokens
            if detectedLanguage == nil { detectedLanguage = language }
            if detectedLanguageToken == nil { detectedLanguageToken = languageToken }

            guard finished else {
                if window.usesInitialPrompt, !initialPromptTokens.isEmpty {
                    decodingRetries += 1
                    windows[index].usesInitialPrompt = false
                    continue
                }
                let replacements = try window.splitAfterOutputLimit()
                decodingRetries += replacements.count
                windows.replaceSubrange(index...index, with: replacements)
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let separator = allText.isEmpty ? "" : " "
                allText.append(trimmed)
                allSegments.append([
                    "text": trimmed,
                    "start": Double(window.range.lowerBound) / Double(WhisperAudioConfig.sampleRate),
                    "end": Double(window.range.upperBound) / Double(WhisperAudioConfig.sampleRate),
                ])
                onSegment?(separator + trimmed)
            }
            index += 1
        }

        try Task.checkCancellation()
        let elapsed = Date().timeIntervalSince(startTime)
        return STTOutput(
            text: allText.joined(separator: " "),
            segments: allSegments.isEmpty ? nil : allSegments,
            language: detectedLanguage ?? generationParameters.language,
            promptTokens: totalPromptTokens,
            generationTokens: totalGenerationTokens,
            totalTokens: totalPromptTokens + totalGenerationTokens,
            decodingRetries: decodingRetries,
            promptTps: elapsed > 0 ? Double(totalPromptTokens) / elapsed : 0,
            generationTps: elapsed > 0 ? Double(totalGenerationTokens) / elapsed : 0,
            totalTime: elapsed,
            peakMemoryUsage: Double(Memory.peakMemory) / 1e9
        )
    }

    // MARK: - Single-chunk transcription

    /// Encode `initialPrompt` once per generate call; every chunk shares the
    /// same `<|startofprev|>` prefix (vocabulary bias, not rolling context).
    private func encodeInitialPrompt(_ prompt: String?) -> [Int] {
        guard let prompt, let tokenizer else { return [] }
        return tokenizer.encodePrompt(prompt, maxTargetPositions: config.maxTargetPositions)
    }

    /// Tied-embedding projection via `asLinear`, which stays correct when the
    /// embedding is quantized (packed weights cannot be matmul'd directly).
    private func projectToVocab(_ hidden: MLXArray) -> MLXArray {
        model.decoder.embedTokens.asLinear(hidden)
    }

    /// Single decoder step from `<|startoftranscript|>` restricted to the
    /// language tokens — the same detection pass mlx_whisper runs when no
    /// language is forced (upstream skipped the language slot entirely in
    /// auto mode, which degrades decoding).
    private func detectLanguageToken(encoderHidden: MLXArray) -> Int? {
        guard let tokenizer, !tokenizer.languageToId.isEmpty else { return nil }
        var caches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
        let sot = MLXArray([Int32(tokenizer.startOfTranscriptId)]).expandedDimensions(axis: 0)
        let hidden = model.decoder(
            tokens: sot,
            startPosition: 0,
            encoderHidden: encoderHidden,
            caches: &caches
        )
        let logits = projectToVocab(hidden[0, -1])
        let logits1D = logits.ndim > 1 ? logits.squeezed() : logits
        eval(logits1D)

        var best: (id: Int, score: Float)?
        let vocabSize = logits1D.dim(-1)
        for id in tokenizer.languageToId.values where id >= 0 && id < vocabSize {
            let score = logits1D[id].item(Float.self)
            if best == nil || score > best!.score {
                best = (id, score)
            }
        }
        return best?.id
    }

    private func transcribeChunk(
        audio: MLXArray,
        generationParameters: STTGenerateParameters,
        initialPromptTokens: [Int] = [],
        languageTokenId: Int? = nil
    ) throws -> (text: String, promptTokens: Int, generationTokens: Int, language: String?, languageTokenId: Int?, finished: Bool) {
        guard let tokenizer else {
            fatalError("WhisperTokenizer not loaded — call fromDirectory before generate.")
        }
        let features = WhisperAudio.encoderFeatures(audio: audio, nMels: config.numMelBins)
        let encoderHidden = model.encoder(features)

        // Auto mode: detect once per dictation (the caller passes the first
        // chunk's token back in for the rest).
        var resolvedLanguageToken = languageTokenId
        if resolvedLanguageToken == nil,
            tokenizer.isMultilingual,
            tokenizer.resolveLanguage(generationParameters.language) == nil
        {
            resolvedLanguageToken = detectLanguageToken(encoderHidden: encoderHidden)
        }

        var caches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
        let promptIds = tokenizer.buildPromptTokens(
            language: generationParameters.language,
            task: "transcribe",
            initialPromptTokens: initialPromptTokens,
            languageTokenId: resolvedLanguageToken
        )

        let promptArray = MLXArray(promptIds.map(Int32.init)).expandedDimensions(axis: 0)
        var hidden = model.decoder(
            tokens: promptArray,
            startPosition: 0,
            encoderHidden: encoderHidden,
            caches: &caches
        )
        var logits = projectToVocab(hidden[0, -1])
        eval(logits)

        var generated: [Int] = []
        var finished = false
        let beginSuppress = generationConfig?.beginSuppressTokens ?? [tokenizer.endOfTextId]
        let suppress = generationConfig?.suppressTokens ?? []

        let maxTokens = max(
            1,
            min(
                generationParameters.maxTokens,
                config.maxTargetPositions - promptIds.count - 1
            )
        )

        for step in 0..<maxTokens {
            // Between GPU evals — the only spot a cancel can interrupt a
            // window without cutting a blocking eval in half.
            try Task.checkCancellation()
            var stepLogits = logits
            if step == 0, !beginSuppress.isEmpty {
                stepLogits = suppressLogits(stepLogits, ids: beginSuppress)
            }
            if !suppress.isEmpty {
                stepLogits = suppressLogits(stepLogits, ids: suppress)
            }
            stepLogits = suppressFromIndex(stepLogits, fromIndex: tokenizer.timestampBeginId)

            let nextToken = sample(stepLogits, temperature: generationParameters.temperature)
            if nextToken == tokenizer.endOfTextId {
                finished = true
                break
            }
            generated.append(nextToken)

            let position = promptIds.count + step
            let tokenArray = MLXArray([Int32(nextToken)]).expandedDimensions(axis: 0)
            hidden = model.decoder(
                tokens: tokenArray,
                startPosition: position,
                encoderHidden: encoderHidden,
                caches: &caches
            )
            logits = projectToVocab(hidden[0, -1])
            eval(logits)
            if generated.count % 256 == 0 {
                Memory.clearCache()
            }
        }

        let text = tokenizer.decode(tokens: generated)
        // The language token sits right after `<|startoftranscript|>` for
        // multilingual models (the prompt may carry a `<|startofprev|>`
        // prefix, so index from the SOT, not from 0).
        var language: String? = nil
        if tokenizer.isMultilingual,
            let sotIndex = promptIds.firstIndex(of: tokenizer.startOfTranscriptId),
            sotIndex + 1 < promptIds.count
        {
            let langTokenId = promptIds[sotIndex + 1]
            for (code, id) in tokenizer.languageToId where id == langTokenId {
                language = code
                break
            }
        }
        return (text, promptIds.count, generated.count, language, resolvedLanguageToken, finished)
    }

    private func sample(_ logits: MLXArray, temperature: Float) -> Int {
        let logits1D = logits.ndim > 1 ? logits.squeezed() : logits
        if temperature <= 0 {
            return logits1D.argMax(axis: -1).item(Int.self)
        }
        let scaled = (logits1D / temperature).expandedDimensions(axis: 0)
        return categorical(scaled).item(Int.self)
    }

    private func suppressLogits(_ logits: MLXArray, ids: [Int]) -> MLXArray {
        if ids.isEmpty { return logits }
        let length = logits.dim(-1)
        var mask = [Float](repeating: 0, count: length)
        for id in ids where id >= 0 && id < length {
            mask[id] = -1e9
        }
        return logits + MLXArray(mask).asType(logits.dtype)
    }

    private func suppressFromIndex(_ logits: MLXArray, fromIndex: Int) -> MLXArray {
        let length = logits.dim(-1)
        if fromIndex >= length { return logits }
        var mask = [Float](repeating: 0, count: length)
        for i in fromIndex..<length { mask[i] = -1e9 }
        return logits + MLXArray(mask).asType(logits.dtype)
    }

    // MARK: - Loading

    /// Source layout for a Whisper safetensors checkpoint.
    enum WeightFormat {
        /// HuggingFace `transformers` layout (`openai/whisper-*`).
        case huggingFace
        /// OpenAI / mlx-whisper layout (`mlx-community/whisper-*`).
        case mlxWhisper
    }

    static func detectFormat(_ weights: [String: MLXArray]) -> WeightFormat {
        for key in weights.keys where key.contains(".blocks.") {
            return .mlxWhisper
        }
        return .huggingFace
    }

    static func sanitize(weights: [String: MLXArray], config: WhisperConfig) -> [String: MLXArray] {
        switch detectFormat(weights) {
        case .huggingFace: return sanitizeHuggingFace(weights)
        case .mlxWhisper: return sanitizeMlxWhisper(weights)
        }
    }

    private static func sanitizeHuggingFace(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            // proj_out is tied to embed_tokens; projectToVocab uses the embedding directly.
            if rawKey == "proj_out.weight" || rawKey == "model.proj_out.weight" {
                continue
            }

            var key = rawKey
            // Re-exports that drop the top-level `model.` still need it for module lookup.
            if !key.hasPrefix("model.") {
                if key.hasPrefix("encoder.") || key.hasPrefix("decoder.") {
                    key = "model." + key
                }
            }

            var newValue = value
            if key == "model.encoder.conv1.weight" || key == "model.encoder.conv2.weight", newValue.ndim == 3 {
                // PyTorch Conv1d: [out, in, kernel] -> MLX Conv1d: [out, kernel, in]
                newValue = newValue.transposed(0, 2, 1)
            }
            sanitized[key] = newValue
        }

        return sanitized
    }

    private static func sanitizeMlxWhisper(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            if rawKey == "alignment_heads" { continue }
            guard let mapped = remapMlxWhisperKey(rawKey) else { continue }
            sanitized[mapped] = value
        }

        // mlx-whisper omits the encoder positional embedding because it's a
        // fixed sinusoid; synthesise it so `update(parameters:verify:.all)` passes.
        let encPosKey = "model.encoder.embed_positions.weight"
        if sanitized[encPosKey] == nil, let conv2 = sanitized["model.encoder.conv2.weight"] {
            sanitized[encPosKey] = whisperSinusoids(length: 1500, channels: conv2.shape[0])
        }

        return sanitized
    }

    private static func whisperSinusoids(length: Int, channels: Int) -> MLXArray {
        precondition(channels % 2 == 0, "Whisper sinusoid channels must be even")
        let half = channels / 2
        let logTimescaleIncrement = log(10000.0) / Double(max(half - 1, 1))
        var values = [Float](repeating: 0, count: length * channels)
        for pos in 0..<length {
            for i in 0..<half {
                let scaledTime = Double(pos) * exp(-logTimescaleIncrement * Double(i))
                values[pos * channels + i] = Float(sin(scaledTime))
                values[pos * channels + half + i] = Float(cos(scaledTime))
            }
        }
        return MLXArray(values).reshaped([length, channels])
    }

    private static func remapMlxWhisperKey(_ rawKey: String) -> String? {
        if rawKey == "encoder.positional_embedding" {
            return "model.encoder.embed_positions.weight"
        }
        if rawKey == "decoder.positional_embedding" {
            return "model.decoder.embed_positions.weight"
        }
        if let rest = stripPrefix(rawKey, "decoder.token_embedding.") {
            // weight, plus scales/biases on quantized checkpoints.
            return "model.decoder.embed_tokens." + rest
        }
        if rawKey == "encoder.conv1.weight" || rawKey == "encoder.conv1.bias"
            || rawKey == "encoder.conv2.weight" || rawKey == "encoder.conv2.bias"
        {
            return "model." + rawKey
        }
        if rawKey.hasPrefix("encoder.ln_post.") {
            return "model.encoder.layer_norm." + String(rawKey.dropFirst("encoder.ln_post.".count))
        }
        if rawKey.hasPrefix("decoder.ln.") {
            return "model.decoder.layer_norm." + String(rawKey.dropFirst("decoder.ln.".count))
        }

        for stem in ["encoder", "decoder"] {
            let blocksPrefix = "\(stem).blocks."
            guard rawKey.hasPrefix(blocksPrefix) else { continue }
            let rest = rawKey.dropFirst(blocksPrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { return nil }
            let layerIndex = String(rest[..<dot])
            let suffix = String(rest[rest.index(after: dot)...])
            guard let mapped = remapBlockSuffix(suffix, isDecoder: stem == "decoder") else { return nil }
            return "model.\(stem).layers.\(layerIndex).\(mapped)"
        }

        return nil
    }

    private static func remapBlockSuffix(_ suffix: String, isDecoder: Bool) -> String? {
        let attnNameMap: [String: String] = [
            "query": "q_proj", "key": "k_proj", "value": "v_proj", "out": "out_proj",
        ]

        if let rest = stripPrefix(suffix, "attn_ln.") {
            return "self_attn_layer_norm.\(rest)"
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn_ln.") {
            return "encoder_attn_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp_ln.") {
            return "final_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp1.") {
            return "fc1.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp2.") {
            return "fc2.\(rest)"
        }
        if let rest = stripPrefix(suffix, "attn.") {
            return remapAttnSuffix(rest, container: "self_attn", attnNameMap: attnNameMap)
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn.") {
            return remapAttnSuffix(rest, container: "encoder_attn", attnNameMap: attnNameMap)
        }
        return nil
    }

    private static func remapAttnSuffix(
        _ suffix: String,
        container: String,
        attnNameMap: [String: String]
    ) -> String? {
        guard let dot = suffix.firstIndex(of: ".") else { return nil }
        let projName = String(suffix[..<dot])
        let tail = String(suffix[suffix.index(after: dot)...])
        guard let mappedProj = attnNameMap[projName] else { return nil }
        return "\(container).\(mappedProj).\(tail)"
    }

    private static func stripPrefix(_ string: String, _ prefix: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    public static func fromDirectory(
        _ modelDirectory: URL,
        cache: HubCache = .default
    ) async throws -> WhisperModel {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperConfig.self, from: configData)

        var generationConfig: WhisperGenerationConfig? = nil
        let generationConfigURL = modelDirectory.appendingPathComponent("generation_config.json")
        if FileManager.default.fileExists(atPath: generationConfigURL.path),
            let data = try? Data(contentsOf: generationConfigURL)
        {
            generationConfig = try? JSONDecoder().decode(WhisperGenerationConfig.self, from: data)
        }

        let model = WhisperModel(config: config, generationConfig: generationConfig)

        let files = try FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil
        )
        let safetensors =
            files
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !safetensors.isEmpty else {
            throw NSError(
                domain: "WhisperModel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No .safetensors files found in \(modelDirectory.path)."]
            )
        }

        var weights: [String: MLXArray] = [:]
        for url in safetensors {
            let shard = try MLX.loadArrays(url: url)
            weights.merge(shard) { _, new in new }
        }
        let sanitized = sanitize(weights: weights, config: config)
        if let quantization = config.quantization {
            // Swap in quantized layers before the update so the checkpoint's
            // packed weights + scales/biases land on matching parameters.
            // Only layers the converter actually quantized carry `scales`.
            MLXNN.quantize(
                model: model,
                groupSize: quantization.groupSize,
                bits: quantization.bits,
                filter: { path, _ in sanitized["\(path).scales"] != nil }
            )
        }
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)

        // mlx-community Whisper repos ship weights only; fetch the tokenizer
        // from the sibling openai/whisper-* repo when missing.
        let tokenizerDir: URL
        if WhisperModelDownloader.hasTokenizerAssets(in: modelDirectory) {
            tokenizerDir = modelDirectory
        } else {
            tokenizerDir = try await downloadTokenizerAssets(
                vocabSize: config.vocabSize,
                cache: cache
            )
            if generationConfig == nil {
                let fetched = tokenizerDir.appendingPathComponent("generation_config.json")
                if let data = try? Data(contentsOf: fetched) {
                    generationConfig = try? JSONDecoder().decode(WhisperGenerationConfig.self, from: data)
                }
            }
        }

        model.tokenizer = try await WhisperTokenizer(
            modelDirectory: modelDirectory,
            baseConfig: config,
            generationConfig: generationConfig,
            tokenizerDirectory: tokenizerDir
        )

        eval(model)
        return model
    }

    private static func downloadTokenizerAssets(
        vocabSize: Int,
        cache: HubCache
    ) async throws -> URL {
        let (tokenizerRepo, tokenizerRevision) = WhisperModelDownloader.tokenizerRepo(
            forVocabSize: vocabSize
        )

        let hfToken =
            ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HF_TOKEN") as? String

        guard let repoID = Repo.ID(rawValue: tokenizerRepo) else {
            throw NSError(
                domain: "WhisperModel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid tokenizer repo: \(tokenizerRepo)"]
            )
        }

        let client: HubClient
        if let token = hfToken, !token.isEmpty {
            client = HubClient(host: HubClient.defaultHost, bearerToken: token, cache: cache)
        } else {
            client = HubClient(cache: cache)
        }
        let resolvedCache = client.cache ?? cache

        let modelSubdir = repoID.description.replacingOccurrences(of: "/", with: "_")
        let targetDir = resolvedCache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent("\(modelSubdir)_tokenizer_only")

        if WhisperModelDownloader.hasTokenizerAssets(in: targetDir) {
            return targetDir
        }

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: targetDir,
            revision: tokenizerRevision,
            matching: WhisperModelDownloader.tokenizerAssetFiles,
            progressHandler: { _ in }
        )

        guard WhisperModelDownloader.hasTokenizerAssets(in: targetDir) else {
            throw NSError(
                domain: "WhisperModel",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Tokenizer fallback download from \(tokenizerRepo) is missing or has zero-byte tokenizer assets."
                ]
            )
        }
        return targetDir
    }

}
