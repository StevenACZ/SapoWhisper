//
//  WhisperModelDownloader.swift
//  MLXWhisper
//
//  App-driven replacement for mlx-audio-swift's ModelUtils loading path:
//  same Hub snapshot layout, but the destination root belongs to the app,
//  progress reaches the UI instead of prints, and the tokenizer assets are
//  prefetched into the model directory so `WhisperModel.fromDirectory`
//  never needs the network at load time.
//

import Foundation
import HuggingFace

public enum WhisperModelDownloadError: LocalizedError {
    case invalidRepo(String)
    case incompleteDownload(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepo(let repo):
            return "Invalid Hugging Face repository ID: \(repo)"
        case .incompleteDownload(let repo):
            return "Downloaded model '\(repo)' has missing or zero-byte weight files."
        }
    }
}

public enum WhisperModelDownloader {

    /// Directory a repo's snapshot lives in under the app-chosen root.
    public static func modelDirectory(repo: String, root: URL) -> URL {
        root.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    /// A model is usable when it has a non-empty weights file, a parseable
    /// config, and local tokenizer assets (no network needed to load).
    public static func isDownloaded(repo: String, root: URL) -> Bool {
        let dir = modelDirectory(repo: repo, root: root)
        guard hasNonEmptySafetensors(in: dir) else { return false }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else { return false }
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("tokenizer.json").path
        )
    }

    /// Bytes on disk for a downloaded model (0 when absent).
    public static func sizeOnDisk(repo: String, root: URL) -> Int64 {
        let dir = modelDirectory(repo: repo, root: root)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            )
        else { return 0 }
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    public static func delete(repo: String, root: URL) {
        try? FileManager.default.removeItem(at: modelDirectory(repo: repo, root: root))
    }

    /// Download (or resume/complete) a model snapshot. `progress` receives
    /// 0...1 fractions on the main actor. Returns the model directory ready
    /// for `WhisperModel.fromDirectory`.
    public static func download(
        repo: String,
        root: URL,
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: repo) else {
            throw WhisperModelDownloadError.invalidRepo(repo)
        }
        let dir = modelDirectory(repo: repo, root: root)
        if isDownloaded(repo: repo, root: root) {
            return dir
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let client = HubClient(cache: .default)
        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: dir,
            revision: "main",
            matching: ["*.safetensors", "*.json", "*.txt", "merges.txt", "vocab.json"],
            progressHandler: { snapshotProgress in
                // Reserve the last 2% for the tokenizer-asset prefetch below.
                progress?(snapshotProgress.fractionCompleted * 0.98)
            }
        )

        guard hasNonEmptySafetensors(in: dir) else {
            try? FileManager.default.removeItem(at: dir)
            throw WhisperModelDownloadError.incompleteDownload(repo)
        }

        try await prefetchTokenizerAssetsIfNeeded(into: dir, client: client)
        await MainActor.run { progress?(1.0) }
        return dir
    }

    // MARK: - Internals

    private static func hasNonEmptySafetensors(in dir: URL) -> Bool {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            )
        else { return false }
        return files.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            return ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
    }

    /// mlx-community Whisper repos ship weights only; fetch the tokenizer
    /// from the matching openai/whisper-* repo straight into the model
    /// directory (same repo selection as `WhisperModel.fromDirectory`).
    private static func prefetchTokenizerAssetsIfNeeded(
        into dir: URL,
        client: HubClient
    ) async throws {
        let tokenizerPath = dir.appendingPathComponent("tokenizer.json")
        guard !FileManager.default.fileExists(atPath: tokenizerPath.path) else { return }

        var vocabSize = 51866
        if let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let size = json["vocab_size"] as? Int
        {
            vocabSize = size
        }
        let tokenizerRepo: String
        switch vocabSize {
        case 51866: tokenizerRepo = "openai/whisper-large-v3"
        case 51865: tokenizerRepo = "openai/whisper-medium"
        case 51864: tokenizerRepo = "openai/whisper-medium.en"
        default: tokenizerRepo = "openai/whisper-large-v3"
        }
        guard let repoID = Repo.ID(rawValue: tokenizerRepo) else {
            throw WhisperModelDownloadError.invalidRepo(tokenizerRepo)
        }

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: dir,
            revision: "main",
            matching: [
                "tokenizer.json",
                "tokenizer_config.json",
                "special_tokens_map.json",
                "added_tokens.json",
                "vocab.json",
                "merges.txt",
                "normalizer.json",
                "generation_config.json",
            ],
            progressHandler: { _ in }
        )

        guard FileManager.default.fileExists(atPath: tokenizerPath.path) else {
            throw WhisperModelDownloadError.incompleteDownload(tokenizerRepo)
        }
    }
}
