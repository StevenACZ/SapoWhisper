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

    public static func delete(repo: String, root: URL) throws {
        let directory = modelDirectory(repo: repo, root: root)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
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

        let client = HubClient(host: URL(string: "https://huggingface.co")!, cache: nil)
        try await downloadFiles(
            repo: repoID, revision: revision, into: dir, client: client,
            matching: { ["safetensors", "json", "txt"].contains(URL(fileURLWithPath: $0).pathExtension) },
            progress: { fraction in progress?(fraction * 0.98) }
        )

        guard hasNonEmptySafetensors(in: dir) else {
            try? FileManager.default.removeItem(at: dir)
            throw WhisperModelDownloadError.incompleteDownload(repo)
        }

        try await prefetchTokenizerAssetsIfNeeded(into: dir, client: client, progress: progress)
        try Task.checkCancellation()
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
        client: HubClient,
        progress: (@MainActor @Sendable (Double) -> Void)?
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

        try await downloadFiles(
            repo: repoID, revision: tokenizerRevision, into: dir, client: client,
            matching: { tokenizerAssetFiles.contains($0) },
            progress: { fraction in progress?(0.98 + fraction * 0.02) }
        )

        guard hasTokenizerAssets(in: dir) else {
            throw WhisperModelDownloadError.incompleteDownload(tokenizerRepo)
        }
    }

    private static func downloadFiles(
        repo: Repo.ID, revision: String, into directory: URL, client: HubClient,
        matching: (String) -> Bool,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let entries = try await client.modelTree(repo, revision: revision)
            .filter { $0.type == .file && matching($0.path) }
            .sorted { $0.path < $1.path }
        guard !entries.isEmpty,
            entries.allSatisfy({
                !$0.path.contains("/") && !$0.path.contains("\\") && $0.path != "." && $0.path != ".."
                    && ($0.size ?? 0) > 0 && ($0.size ?? 0) < 1_000_000_000_000
            })
        else { throw WhisperModelDownloadError.incompleteDownload(repo.rawValue) }
        let total = entries.reduce(Int64(0)) { $0 + Int64($1.size!) }
        var retained = entries.map { entry -> Int64 in
            let destination = directory.appendingPathComponent(entry.path)
            let expected = Int64(entry.size!)
            let completeSize = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if completeSize == expected { return expected }
            let partialSize = Int64(
                (try? destination.appendingPathExtension("partial")
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return partialSize <= expected ? partialSize : 0
        }
        await progress(Double(retained.reduce(0, +)) / Double(total))
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let size = Int64(entry.size!)
            let destination = directory.appendingPathComponent(entry.path)
            if Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) != size {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                let baseline = retained.reduce(0, +) - retained[index]
                let transfer = WhisperFileDownload(destination: destination, expectedSize: size) { received in
                    let fraction = Double(baseline + received) / Double(total)
                    Task { @MainActor in progress(fraction) }
                }
                let url = URL(string: "https://huggingface.co")!
                    .appendingPathComponent(repo.rawValue)
                    .appendingPathComponent("resolve")
                    .appendingPathComponent(revision)
                    .appendingPathComponent(entry.path)
                try await transfer.download(from: url)
            }
            retained[index] = size
            await progress(Double(retained.reduce(0, +)) / Double(total))
        }
    }

}
