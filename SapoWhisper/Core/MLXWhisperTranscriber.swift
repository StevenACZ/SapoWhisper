//
//  MLXWhisperTranscriber.swift
//  SapoWhisper
//
//  Local Whisper on Apple Silicon via MLX (vendored engine in
//  LocalPackages/MLXWhisper), running the model on the M-series GPU with
//  the user vocabulary conditioning the decoder as a real initial prompt.
//

import AVFoundation
import Foundation
import MLXWhisper
import os

/// Owns the non-Sendable `WhisperModel` and runs GPU inference off the main
/// actor. Actor isolation doubles as the reentrancy guard for the model.
actor MLXWhisperEngine {
    private var model: WhisperModel?
    /// Monotonic load counter: a cancelled load frees exactly the weights it
    /// loaded (`unload(ifGeneration:)`) without clobbering a newer load.
    private var loadGeneration = 0

    var isLoaded: Bool { model != nil }

    @discardableResult
    func load(directory: URL) async throws -> Int {
        if model != nil {
            // Direct load-over-load: drop the resident weights and their
            // buffer pool before the new ones allocate, or peak RAM briefly
            // doubles and the old pool stays cached.
            unload()
        }
        model = try await WhisperModel.fromDirectory(directory)
        loadGeneration += 1
        return loadGeneration
    }

    func unload() {
        model = nil
        // Dropping the model frees its arrays; the buffer pool needs an
        // explicit clear or MLX keeps ~hundreds of MB resident.
        MLXWhisperRuntime.clearMemoryCache()
    }

    /// Unload only while this generation's model is still the resident one.
    func unload(ifGeneration generation: Int) {
        guard generation == loadGeneration else { return }
        unload()
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
        // Throws CancellationError when the caller's task is cancelled — the
        // decode loop checks between windows and steps, so a retranscribe of
        // a long WAV stops early instead of running to completion.
        return try model.generate(samples: samples, generationParameters: parameters)
    }
}

/// Per-model snapshot download lifecycle, driven by the settings UI. The
/// fractions inside `downloading`/`paused` keep the row's progress ring
/// stable across pause/resume.
nonisolated enum MLXModelDownloadPhase: Equatable {
    case idle
    case downloading(Double)
    case paused(Double)
    case failed(String)

    var fraction: Double? {
        switch self {
        case .downloading(let fraction), .paused(let fraction):
            return fraction
        case .idle, .failed:
            return nil
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Maneja la transcripcion de audio usando el motor MLX (100% local).
///
/// `@Observable`: views read the individual progress properties, so
/// download ticks re-render only the progress UI.
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
    /// when the flag actually flips.
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

    /// Models with a complete snapshot on disk (the recording gate checks it
    /// for the R4 reload-on-demand path).
    var downloadedModels: Set<MLXWhisperModel> = []

    /// Download lifecycle per tier — drives the per-row progress/pause/error
    /// UI in Settings. Missing entry = `.idle`.
    var downloadPhases: [MLXWhisperModel: MLXModelDownloadPhase] = [:]

    /// Fired when a standalone download completes, so the owner can load the
    /// model if it is the active selection.
    @ObservationIgnored var onDownloadCompleted: ((MLXWhisperModel) -> Void)?

    // MARK: - Private Properties

    private let engine = MLXWhisperEngine()
    private var currentModel: MLXWhisperModel?
    private var loadingModel: MLXWhisperModel?
    private var loadTask: Task<Void, Error>?
    /// Generation of the currently resident model; a late fire-and-forget
    /// unload targets this generation so it can never clobber a newer load.
    private var currentLoadGeneration = 0
    @ObservationIgnored private var downloadTasks: [MLXWhisperModel: Task<URL, Error>] = [:]
    private var idleUnloadTimer: Timer?

    // MARK: - Initialization

    init() {
        refreshDownloadedModels()
        SapoLog.recording.info(
            "MLXWhisperTranscriber initialized downloaded=\(self.downloadedModels.count, privacy: .public)"
        )
    }

    /// Snapshot root under Application Support — owned entirely by the app
    /// (never a shared HuggingFace cache).
    static var modelsRootDirectory: URL {
        AppRuntimePaths.applicationSupport.appendingPathComponent("MLXModels", isDirectory: true)
    }

    // MARK: - Model Management

    /// Descarga (si hace falta) y carga un modelo MLX. Second calls for the
    /// model already in flight await it instead of restarting (R4 mirror).
    func loadModel(_ model: MLXWhisperModel) async throws {
        try Task.checkCancellation()

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

            let directory: URL
            if alreadyDownloaded {
                directory = WhisperModelDownloader.modelDirectory(repo: model.rawValue, root: root)
            } else {
                loadingState = .downloading
                loadingMessage = "mlx.state.downloading".localized(model.displayName)
                // Shared with the standalone Settings download path, so a tap
                // on the row and a selection load never race two snapshots.
                directory = try await sharedDownloadTask(for: model).value
            }

            try Task.checkCancellation()

            loadingState = .loading
            loadingMessage = "mlx.state.loading".localized(model.displayName)
            loadingProgress = alreadyDownloaded ? 0.5 : 0.9

            let generation = try await engine.load(directory: directory)

            // An engine/model switch mid-load cancelled this task: the weights
            // just loaded must not stay resident under the new selection.
            if Task.isCancelled {
                await engine.unload(ifGeneration: generation)
                throw CancellationError()
            }

            loadingState = .ready
            loadingMessage = "mlx.state.ready".localized
            loadingProgress = 1.0
            currentModel = model
            currentModelName = model.displayName
            currentLoadGeneration = generation
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
            let detail = LogSanitizer.errorDiagnostic(error, state: "mlx-model-load")
            SapoLog.recording.error(
                "MLX failed \(detail, privacy: .public)"
            )
            throw MLXWhisperError.modelLoadFailed(message)
        }
    }

    // MARK: - Download Management

    func downloadPhase(_ model: MLXWhisperModel) -> MLXModelDownloadPhase {
        downloadPhases[model] ?? .idle
    }

    /// True while any tier is actively downloading.
    var isAnyDownloadActive: Bool {
        downloadPhases.values.contains { $0.isDownloading }
    }

    /// Starts (or resumes after pause/failure) the snapshot download for a
    /// tier without loading it into memory.
    func startDownload(_ model: MLXWhisperModel) {
        _ = sharedDownloadTask(for: model)
    }

    /// Cancels the in-flight task but keeps the partial snapshot on disk;
    /// resuming re-enters the downloader, which skips completed files.
    func pauseDownload(_ model: MLXWhisperModel) {
        guard let task = downloadTasks[model] else { return }
        let fraction = downloadPhase(model).fraction ?? 0
        downloadTasks[model] = nil
        downloadPhases[model] = .paused(fraction)
        task.cancel()
        SapoLog.settings.info(
            "MLX download paused model=\(model.rawValue, privacy: .public) percent=\(Int(fraction * 100), privacy: .public)"
        )
    }

    /// Aborts the download and deletes the partial snapshot — cancel means
    /// "I changed my mind", so the disk space comes back.
    func cancelDownload(_ model: MLXWhisperModel) {
        let task = downloadTasks[model]
        downloadTasks[model] = nil
        downloadPhases[model] = .idle
        task?.cancel()
        WhisperModelDownloader.delete(repo: model.rawValue, root: Self.modelsRootDirectory)
        downloadedModels.remove(model)
        SapoLog.settings.info("MLX download cancelled model=\(model.rawValue, privacy: .public)")
    }

    /// One download task per tier, shared by the Settings row and the
    /// selection-load path. Progress feeds the per-row phase always, and the
    /// card-level loading bar only while this model is the one being loaded.
    private func sharedDownloadTask(for model: MLXWhisperModel) -> Task<URL, Error> {
        if let existing = downloadTasks[model] { return existing }

        downloadPhases[model] = .downloading(downloadPhase(model).fraction ?? 0)
        SapoLog.recording.info(
            "MLX model download started model=\(model.rawValue, privacy: .public)"
        )

        let task = Task { [weak self] () throws -> URL in
            do {
                let directory = try await WhisperModelDownloader.download(
                    repo: model.rawValue,
                    revision: model.revision,
                    root: Self.modelsRootDirectory,
                    progress: { fraction in
                        guard let self else { return }
                        // Pause/cancel detached this task — stop publishing.
                        guard self.downloadTasks[model] != nil else { return }
                        self.downloadPhases[model] = .downloading(fraction)
                        if self.loadingModel == model, self.isLoading {
                            self.loadingProgress = fraction * 0.9
                            self.loadingMessage = "mlx.state.downloading_percent".localized(
                                model.displayName, String(Int(fraction * 100))
                            )
                        }
                    }
                )
                guard let self else { return directory }
                self.downloadTasks[model] = nil
                self.downloadPhases[model] = .idle
                self.markAsDownloaded(model)
                SapoLog.recording.info(
                    "MLX model download complete model=\(model.rawValue, privacy: .public)"
                )
                self.onDownloadCompleted?(model)
                return directory
            } catch {
                // Pause/cancel already set the phase they want; only a real
                // failure of a still-attached task lands in `.failed`.
                if let self, !Task.isCancelled, self.downloadTasks[model] != nil {
                    self.downloadTasks[model] = nil
                    self.downloadPhases[model] = .failed(error.localizedDescription)
                    let detail = LogSanitizer.errorDiagnostic(error, state: "mlx-model-download")
                    SapoLog.recording.error(
                        "MLX failed \(detail, privacy: .public)"
                    )
                }
                throw error
            }
        }
        downloadTasks[model] = task
        return task
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
        // Generation-scoped: if a newer load lands on the actor before this
        // task, the stale unload is a no-op instead of dropping fresh weights
        // (Task.cancel alone never frees what a load already allocated).
        let generation = currentLoadGeneration
        Task {
            await engine.unload(ifGeneration: generation)
        }
        SapoLog.recording.info("MLX model unloaded")
    }

    // MARK: - R4: idle unload

    /// Re-arms the idle timer after model activity (load, transcription).
    /// With the setting at 0 (default) the model stays pinned in RAM.
    func noteActivityForIdleUnload() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil

        let minutes = AppPreferences.defaults.integer(forKey: Constants.StorageKeys.mlxWhisperUnloadAfterMinutes)
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
        // Defense in depth: history retranscribe can reach this on a second
        // path; the actor serializes the model, this flag keeps a queued
        // second inference from piling up behind it.
        guard !isTranscribing else {
            throw MLXWhisperError.transcriptionInProgress
        }

        isTranscribing = true
        errorMessage = nil
        defer {
            isTranscribing = false
            noteActivityForIdleUnload()
        }

        SapoLog.recording.info("MLX transcription started")

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
            if output.decodingRetries > 0 {
                SapoLog.recording.notice("MLX decoding recovered output limits retries=\(output.decodingRetries, privacy: .public)")
            }
            let transcription = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            SapoLog.recording.info(
                "MLX transcription complete chars=\(transcription.count, privacy: .public) seconds=\(String(format: "%.2f", output.totalTime), privacy: .public) promptTokens=\(output.promptTokens, privacy: .public)"
            )
            return transcription
        } catch is CancellationError {
            // Cancel is not a failure: no errorMessage, callers see the
            // CancellationError itself.
            SapoLog.recording.info("MLX transcription cancelled")
            throw CancellationError()
        } catch WhisperDecodingError.outputLimit {
            let failure = TranscriptionFailure(
                kind: .modelOutputLimit, engine: TranscriptionEngine.mlxWhisper.displayName,
                technicalDetail: "WhisperDecodingError.outputLimit"
            )
            errorMessage = failure.localizedDescription
            throw failure
        } catch let error as MLXWhisperError {
            errorMessage = error.localizedDescription
            throw error
        } catch {
            let message = error.localizedDescription
            errorMessage = "error.mlx.transcription".localized(message)
            let detail = LogSanitizer.errorDiagnostic(error, state: "mlx-transcription")
            SapoLog.recording.error(
                "MLX failed \(detail, privacy: .public)"
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

            let source = AudioConverterInputSource(buffer: sourceBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: source.provide)
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
        if let task = downloadTasks[model] {
            downloadTasks[model] = nil
            task.cancel()
        }
        downloadPhases[model] = .idle
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
