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

    /// Treating a subset of these as "downloaded" leaves a tier permanently
    /// stuck: the download early-returns on the same check.
    public static let tokenizerAssetFiles = [
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "vocab.json",
        "merges.txt",
        "normalizer.json",
        "generation_config.json",
    ]

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
        return hasTokenizerAssets(in: dir)
    }

    static func hasTokenizerAssets(in dir: URL) -> Bool {
        tokenizerAssetFiles.allSatisfy { name in
            let file = dir.appendingPathComponent(name)
            return ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
        }
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

    /// Download (or resume/complete) a model snapshot. `revision` should be
    /// a pinned commit sha so a moved or compromised branch can never change
    /// what lands on disk. `progress` receives 0...1 fractions on the main
    /// actor. Returns the model directory ready for
    /// `WhisperModel.fromDirectory`.
    public static func download(
        repo: String,
        revision: String = "main",
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
            revision: revision,
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

    /// Tokenizer-asset repo for a Whisper vocab size, pinned to a concrete
    /// revision (commit shas resolved 2026-07-09) like the model snapshots.
    static func tokenizerRepo(forVocabSize vocabSize: Int) -> (repo: String, revision: String) {
        switch vocabSize {
        case 51865: return ("openai/whisper-medium", "abdf7c39ab9d0397620ccaea8974cc764cd0953e")
        case 51864: return ("openai/whisper-medium.en", "2e98eb6279edf5095af0c8dedb36bdec0acd172b")
        default: return ("openai/whisper-large-v3", "06f233fe06e710322aca913c1bc4249a0d71fce1")
        }
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
        guard !hasTokenizerAssets(in: dir) else { return }

        var vocabSize = 51866
        if let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let size = (json["vocab_size"] as? Int) ?? (json["n_vocab"] as? Int)
        {
            vocabSize = size
        }
        let (tokenizerRepo, tokenizerRevision) = Self.tokenizerRepo(forVocabSize: vocabSize)
        guard let repoID = Repo.ID(rawValue: tokenizerRepo) else {
            throw WhisperModelDownloadError.invalidRepo(tokenizerRepo)
        }

        _ = try await client.downloadSnapshot(
            of: repoID,
            kind: .model,
            to: dir,
            revision: tokenizerRevision,
            matching: tokenizerAssetFiles,
            progressHandler: { _ in }
        )

        guard hasTokenizerAssets(in: dir) else {
            throw WhisperModelDownloadError.incompleteDownload(tokenizerRepo)
        }
    }
}
