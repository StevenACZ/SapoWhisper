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

    /// Sidelined audio sits outside `audioDir`, so neither the orphan sweep nor
    /// `enforceAudioStorageLimit` can ever reclaim it; without a window of its
    /// own it would grow for the life of the install.
    static let sidelinedRetention: TimeInterval = 30 * 24 * 60 * 60
    private static let sidelinedPrefix = "audio.corrupt-"

    private let audioDir: URL

    init(appDirectory: URL) {
        audioDir = appDirectory.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Voice recordings + transcripts DB live here: owner-only access, so
        // other same-user processes can't casually read them.
        for dir in [appDirectory, audioDir] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        pruneSidelinedAudio()
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
            let detail = TranscriptionFailure.diagnosticDetail(for: error)
            SapoLog.recording.error(
                "History audio save failed error=\(detail, privacy: .public)"
            )
            return nil
        }
    }

    func deleteAudioFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Corruption recovery: the rows that referenced these WAVs are gone, so the
    /// orphan sweep would delete every one of them. The directory moves aside
    /// under the same stamp as the sidelined DB and stays readable in Finder
    /// until `sidelinedRetention` expires.
    func sidelineAll(stamp: Int) {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(atPath: audioDir.path)) ?? []
        guard !contents.isEmpty else { return }

        let sidelined = audioDir.deletingLastPathComponent()
            .appendingPathComponent("\(Self.sidelinedPrefix)\(stamp)")
        do {
            try fileManager.moveItem(at: audioDir, to: sidelined)
        } catch {
            let detail = TranscriptionFailure.diagnosticDetail(for: error)
            SapoLog.recording.error(
                "History audio sideline failed error=\(detail, privacy: .public)"
            )
            return
        }
        try? fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDir.path)
        SapoLog.recording.error(
            "History audio sidelined stamp=\(stamp, privacy: .public) files=\(contents.count, privacy: .public)"
        )
    }

    func pruneSidelinedAudio(now: Date = Date()) {
        let fileManager = FileManager.default
        let parent = audioDir.deletingLastPathComponent()
        let contents = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []

        for directory in contents {
            let name = directory.lastPathComponent
            guard name.hasPrefix(Self.sidelinedPrefix),
                let stamp = TimeInterval(name.dropFirst(Self.sidelinedPrefix.count)),
                now.timeIntervalSince1970 - stamp > Self.sidelinedRetention
            else { continue }
            try? fileManager.removeItem(at: directory)
            SapoLog.recording.info("History audio sideline expired")
        }
    }

    /// True when `url` is inside the permanent audio directory. Symlinks are
    /// resolved on both sides (/var vs /private/var) like the orphan sweep.
    func ownsFile(at url: URL) -> Bool {
        let filePath = url.resolvingSymlinksInPath().path
        let dirPath = audioDir.resolvingSymlinksInPath().path
        return filePath.hasPrefix(dirPath + "/")
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
