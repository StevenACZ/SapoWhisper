//
//  MLXWhisperTranscriber.swift
//  SapoWhisper
//
//  Local Whisper on Apple Silicon via MLX (vendored engine in
//  LocalPackages/MLXWhisper). Same weights as WhisperKit's turbo but ~6x
//  faster on the M-series GPU (benched 2026-07-05), with the user
//  vocabulary conditioning the decoder as a real initial prompt.
//

import AVFoundation
import Foundation
import MLXWhisper
import os

/// Owns the non-Sendable `WhisperModel` and runs GPU inference off the main
/// actor. Actor isolation doubles as the reentrancy guard for the model.
actor MLXWhisperEngine {
    private var model: WhisperModel?

    var isLoaded: Bool { model != nil }

    func load(directory: URL) async throws {
        model = try await WhisperModel.fromDirectory(directory)
    }

    func unload() {
        model = nil
        // Dropping the model frees its arrays; the buffer pool needs an
        // explicit clear or MLX keeps ~hundreds of MB resident.
        MLXWhisperRuntime.clearMemoryCache()
    }

    func transcribe(samples: [Float], language: String?, initialPrompt: String?) throws -> STTOutput {
        guard let model else {
            throw MLXWhisperError.modelNotLoaded
        }
        let parameters = STTGenerateParameters(
            maxTokens: model.config.maxTargetPositions - 16,
            temperature: 0.0,
            language: language,
            initialPrompt: initialPrompt
        )
        return model.generate(samples: samples, generationParameters: parameters)
    }
}

/// Maneja la transcripcion de audio usando el motor MLX (100% local).
///
/// `@Observable` like `WhisperKitTranscriber`: views read the individual
/// progress properties, so download ticks re-render only the progress UI.
@MainActor
@Observable
class MLXWhisperTranscriber {

    enum LoadingState: String {
        case idle
        case downloading
        case loading
        case ready
        case error
    }

    // MARK: - Observable State

    /// Logic hooks for the owning ViewModel; fired on the main actor only
    /// when the flag actually flips (same contract as WhisperKitTranscriber).
    @ObservationIgnored var onLoadingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onModelLoadedChanged: ((Bool) -> Void)?
    @ObservationIgnored var onTranscribingChanged: ((Bool) -> Void)?

    var isModelLoaded = false {
        didSet {
            if oldValue != isModelLoaded { onModelLoadedChanged?(isModelLoaded) }
        }
    }
    var isLoading = false {
        didSet {
            if oldValue != isLoading { onLoadingChanged?(isLoading) }
        }
    }
    var isTranscribing = false {
        didSet {
            if oldValue != isTranscribing { onTranscribingChanged?(isTranscribing) }
        }
    }
    var loadingProgress: Double = 0
    var loadingMessage: String = ""
    var loadingState: LoadingState = .idle
    var errorMessage: String?
    var currentModelName: String?

    /// Models with a complete snapshot on disk (mirrors the WhisperKit set;
    /// the recording gate checks it for the R4 reload-on-demand path).
    var downloadedModels: Set<MLXWhisperModel> = []

    // MARK: - Private Properties

    private let engine = MLXWhisperEngine()
    private var currentModel: MLXWhisperModel?
    private var loadingModel: MLXWhisperModel?
    private var loadTask: Task<Void, Error>?
    private var idleUnloadTimer: Timer?

    // MARK: - Initialization

    init() {
        refreshDownloadedModels()
        SapoLog.recording.info(
            "MLXWhisperTranscriber initialized downloaded=\(self.downloadedModels.count, privacy: .public)"
        )
    }

    /// Snapshot root under Application Support — owned by the app, unlike
    /// WhisperKit's shared HuggingFace caches.
    static var modelsRootDirectory: URL {
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return
            appSupport
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("MLXModels")
    }

    // MARK: - Model Management

    /// Descarga (si hace falta) y carga un modelo MLX. Second calls for the
    /// model already in flight await it instead of restarting (R4 mirror).
    func loadModel(_ model: MLXWhisperModel) async throws {
        if currentModel == model, isModelLoaded, !isLoading {
            return
        }

        if loadingModel == model, let inFlight = loadTask {
            try await inFlight.value
            return
        }

        if let existingTask = loadTask {
            SapoLog.recording.info("Cancelling previous MLX load")
            existingTask.cancel()
            loadTask = nil
        }

        let task = Task {
            try await performLoadModel(model)
        }
        loadTask = task
        loadingModel = model
        defer { loadingModel = nil }
        try await task.value
        loadTask = nil
    }

    private func performLoadModel(_ model: MLXWhisperModel) async throws {
        isLoading = true
        isModelLoaded = false
        loadingProgress = 0
        errorMessage = nil
        defer { isLoading = false }

        do {
            let root = Self.modelsRootDirectory
            let alreadyDownloaded = WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: root)

            if !alreadyDownloaded {
                loadingState = .downloading
                loadingMessage = "mlx.state.downloading".localized(model.displayName)
                SapoLog.recording.info(
                    "MLX model download started model=\(model.rawValue, privacy: .public)"
                )
            }

            let directory = try await WhisperModelDownloader.download(
                repo: model.rawValue,
                root: root,
                progress: { [weak self] fraction in
                    guard let self, !alreadyDownloaded else { return }
                    self.loadingProgress = fraction * 0.9
                    let percent = Int(fraction * 100)
                    self.loadingMessage = "mlx.state.downloading_percent".localized(
                        model.displayName, String(percent)
                    )
                }
            )
            markAsDownloaded(model)

            try Task.checkCancellation()

            loadingState = .loading
            loadingMessage = "mlx.state.loading".localized(model.displayName)
            loadingProgress = alreadyDownloaded ? 0.5 : 0.9

            try await engine.load(directory: directory)

            loadingState = .ready
            loadingMessage = "mlx.state.ready".localized
            loadingProgress = 1.0
            currentModel = model
            currentModelName = model.displayName
            isModelLoaded = true
            noteActivityForIdleUnload()
            SapoLog.recording.info(
                "MLX model loaded model=\(model.rawValue, privacy: .public)"
            )
        } catch is CancellationError {
            loadingState = .idle
            loadingMessage = ""
            throw CancellationError()
        } catch {
            loadingState = .error
            let message = error.localizedDescription
            errorMessage = "error.mlx.model_load".localized(message)
            SapoLog.recording.error(
                "MLX model load failed error=\(message, privacy: .public)"
            )
            throw MLXWhisperError.modelLoadFailed(message)
        }
    }

    /// Descarga el modelo actual de memoria.
    func unloadModel() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil
        loadTask?.cancel()
        loadTask = nil
        isModelLoaded = false
        isLoading = false
        isTranscribing = false
        loadingProgress = 0
        loadingMessage = ""
        loadingState = .idle
        currentModel = nil
        currentModelName = nil
        Task {
            await engine.unload()
        }
        SapoLog.recording.info("MLX model unloaded")
    }

    // MARK: - R4: idle unload

    /// Re-arms the idle timer after model activity (load, transcription).
    /// With the setting at 0 (default) the model stays pinned in RAM.
    func noteActivityForIdleUnload() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil

        let minutes = UserDefaults.standard.integer(forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes)
        guard minutes > 0, isModelLoaded else { return }

        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            // Scheduled on RunLoop.main, so the timer always fires on main.
            MainActor.assumeIsolated {
                self?.unloadAfterIdle(configuredMinutes: minutes)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        idleUnloadTimer = timer
    }

    private func unloadAfterIdle(configuredMinutes: Int) {
        guard isModelLoaded, !isTranscribing, !isLoading else {
            // Busy right at the deadline: try again on the next activity tick.
            noteActivityForIdleUnload()
            return
        }
        SapoLog.performance.info(
            "MLX model unloaded after idle minutes=\(configuredMinutes, privacy: .public)"
        )
        unloadModel()
    }

    // MARK: - Transcription

    /// Transcribe un archivo de audio usando el motor MLX.
    func transcribe(audioURL: URL, language: String = "es") async throws -> String {
        guard isModelLoaded else {
            throw MLXWhisperError.modelNotLoaded
        }
        // Defense-in-depth mirror of WhisperKit: history retranscribe can
        // reach this on a second path; the actor serializes the model, this
        // flag keeps a queued second inference from piling up behind it.
        guard !isTranscribing else {
            throw MLXWhisperError.transcriptionInProgress
        }

        isTranscribing = true
        errorMessage = nil
        defer {
            isTranscribing = false
            noteActivityForIdleUnload()
        }

        SapoLog.recording.info(
            "MLX transcription started file=\(audioURL.lastPathComponent, privacy: .public)"
        )

        // Whisper-style initial prompt: the user's canonical vocabulary
        // conditions the decoder so keyterms come out spelled right.
        let vocabularyPrompt = VocabularyManager.shared.initialPromptText()
        let initialPrompt = vocabularyPrompt.isEmpty ? nil : vocabularyPrompt
        let languageCode = TranscriptionLanguageCatalog.whisperLanguageCode(for: language)

        do {
            let samples = try await Self.loadSamples16kMono(url: audioURL)
            let output = try await engine.transcribe(
                samples: samples,
                language: languageCode,
                initialPrompt: initialPrompt
            )
            let transcription = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            SapoLog.recording.info(
                "MLX transcription complete chars=\(transcription.count, privacy: .public) seconds=\(String(format: "%.2f", output.totalTime), privacy: .public) promptTokens=\(output.promptTokens, privacy: .public)"
            )
            return transcription
        } catch let error as MLXWhisperError {
            errorMessage = error.localizedDescription
            throw error
        } catch {
            let message = error.localizedDescription
            errorMessage = "error.mlx.transcription".localized(message)
            SapoLog.recording.error(
                "MLX transcription failed error=\(message, privacy: .public)"
            )
            throw MLXWhisperError.transcriptionFailed(message)
        }
    }

    /// Decode any audio file to 16 kHz mono Float32 (whisper-family WAVs are
    /// captured at 16 kHz already; history retranscribe can bring 48 kHz).
    /// Runs off the main actor — decoding a long WAV is not a UI-thread job.
    @concurrent
    private static func loadSamples16kMono(url: URL) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)
        else {
            throw MLXWhisperError.transcriptionFailed("audio converter unavailable")
        }

        let sourceCapacity: AVAudioFrameCount = 65536
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceCapacity)
        else {
            throw MLXWhisperError.transcriptionFailed("audio buffer allocation failed")
        }

        var samples: [Float] = []
        while file.framePosition < file.length {
            // Reading at exact EOF throws on AVAudioFile; the loop gates on
            // framePosition so the last read never lands past the end.
            try file.read(into: sourceBuffer)
            if sourceBuffer.frameLength == 0 { break }

            let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                throw MLXWhisperError.transcriptionFailed("audio buffer allocation failed")
            }

            // The input block is @Sendable; a class box keeps the one-shot
            // flag mutable without capturing a local var in concurrent code.
            final class FeedState: @unchecked Sendable { var fed = false }
            let feedState = FeedState()
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if feedState.fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                feedState.fed = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if status == .error {
                throw MLXWhisperError.transcriptionFailed(
                    conversionError?.localizedDescription ?? "audio conversion failed"
                )
            }
            if let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength))
                )
            }
            if status == .endOfStream { break }
        }
        return samples
    }

    // MARK: - Model Storage Management

    var loadedModelName: String? {
        currentModelName
    }

    func isModelDownloaded(_ model: MLXWhisperModel) -> Bool {
        if downloadedModels.contains(model) { return true }
        if WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: Self.modelsRootDirectory) {
            downloadedModels.insert(model)
            return true
        }
        return false
    }

    private func markAsDownloaded(_ model: MLXWhisperModel) {
        downloadedModels.insert(model)
    }

    func refreshDownloadedModels() {
        var found: Set<MLXWhisperModel> = []
        for model in MLXWhisperModel.allCases
        where WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: Self.modelsRootDirectory) {
            found.insert(model)
        }
        downloadedModels = found
    }

    func downloadedModelSize(_ model: MLXWhisperModel) -> Int64? {
        let size = WhisperModelDownloader.sizeOnDisk(repo: model.rawValue, root: Self.modelsRootDirectory)
        return size > 0 ? size : nil
    }

    func deleteDownloadedModel(_ model: MLXWhisperModel) {
        if currentModel == model {
            unloadModel()
        }
        WhisperModelDownloader.delete(repo: model.rawValue, root: Self.modelsRootDirectory)
        var newSet = downloadedModels
        newSet.remove(model)
        downloadedModels = newSet
        SapoLog.recording.info(
            "MLX model deleted model=\(model.rawValue, privacy: .public)"
        )
    }

    func getDownloadedModelsInfo() -> [(model: MLXWhisperModel, size: Int64)] {
        MLXWhisperModel.allCases.compactMap { model in
            guard isModelDownloaded(model), let size = downloadedModelSize(model) else { return nil }
            return (model, size)
        }
    }
}

// MARK: - Errors

enum MLXWhisperError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case transcriptionInProgress

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "error.mlx.model_not_loaded".localized
        case .modelLoadFailed(let message):
            return "error.mlx.model_load".localized(message)
        case .transcriptionFailed(let message):
            return "error.mlx.transcription".localized(message)
        case .transcriptionInProgress:
            return "error.mlx.in_progress".localized
        }
    }
}

// MARK: - TranscriptionEngineSession

extension MLXWhisperTranscriber: TranscriptionEngineSession {
    var isReady: Bool { isModelLoaded }
    var isBusy: Bool { isTranscribing }
}
