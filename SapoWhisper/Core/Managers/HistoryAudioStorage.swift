//
//  HistoryAudioStorage.swift
//  SapoWhisper
//

import Foundation
import os

nonisolated final class HistoryAudioStorage: Sendable {
    static let defaultMaxStorageMB = 500
    /// H6: user-selectable cap in Settings; enforcement trims to 80% so the
    /// sweep does not retrigger on every save.
    static var maxAudioStorageBytes: Int64 {
        let configuredMB = UserDefaults.standard.integer(forKey: Constants.StorageKeys.historyAudioMaxMB)
        let megabytes = configuredMB > 0 ? configuredMB : defaultMaxStorageMB
        return Int64(megabytes) * 1024 * 1024
    }
    static var targetAudioStorageBytes: Int64 {
        maxAudioStorageBytes * 8 / 10
    }

    private let audioDir: URL

    init(appDirectory: URL) {
        audioDir = appDirectory.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    func saveAudioFile(from sourceURL: URL) -> String? {
        // UUID, not a float timestamp: two saves in the same sub-second window
        // (a retry plus an orphan sweep, a test) would otherwise collide, the
        // second copyItem would fail, and the audio would be lost silently.
        let filename = "audio_\(UUID().uuidString).wav"
        let destURL = audioDir.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL.path
        } catch {
            SapoLog.recording.error(
                "History audio save failed error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func deleteAudioFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func directorySize() -> Int64 {
        audioFiles().reduce(0) { $0 + $1.size }
    }

    func fileSize(at path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value) ?? 0
    }

    func deleteOrphanedAudioFiles(referencedPaths: Set<String>) {
        // Match by unique file name rather than full path. Saved WAVs use UUID
        // names, so the name identifies the row's audio unambiguously, while the
        // stored audio_path and the enumerated file URL can disagree on path
        // normalization (e.g. a symlinked parent like /var vs /private/var) and
        // make a referenced file look orphaned. Unknown files are still swept.
        let referencedNames = Set(referencedPaths.map { ($0 as NSString).lastPathComponent })
        for file in audioFiles() where !referencedNames.contains(file.url.lastPathComponent) {
            deleteAudioFile(at: file.url.path)
        }
    }

    private func audioFiles() -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: audioDir,
                includingPropertiesForKeys: keys
            )
        else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            return (url, Int64(values?.fileSize ?? 0))
        }
    }
}
