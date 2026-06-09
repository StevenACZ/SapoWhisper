//
//  TemporaryAudioStorage.swift
//  SapoWhisper
//

import Foundation
import os

/// App-private home for in-flight WAVs (recordings awaiting transcription,
/// mic-test samples). Files use unguessable UUID names inside
/// `~/Library/Caches/oli.SapoWhisper/audio-temp/` instead of timestamp names
/// in the shared system temp directory, and a launch sweep removes anything
/// stale that an earlier crash or abandoned retry left behind.
enum TemporaryAudioStorage {
    /// Files older than this are considered abandoned by the launch sweep.
    private static let staleAge: TimeInterval = 24 * 60 * 60

    /// Prefixes of WAVs that older app versions wrote to the shared temp dir.
    private static let legacyPrefixes = [
        "recording_", "flux_recording_", "mic_test_raw_", "mic_test_compressed_",
    ]

    static var directory: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent("oli.SapoWhisper", isDirectory: true)
            .appendingPathComponent("audio-temp", isDirectory: true)
    }

    /// Returns a fresh UUID-named WAV URL, creating the directory if needed.
    static func makeWAVURL(prefix: String) -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(prefix)_\(UUID().uuidString).wav")
    }

    /// Removes temp WAVs older than 24h plus legacy timestamp-named WAVs that
    /// previous versions left in the shared system temp directory.
    static func sweepStaleFiles(now: Date = Date()) {
        var removed = 0
        let fileManager = FileManager.default

        if let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            for file in files {
                let modified =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) > staleAge else { continue }
                try? fileManager.removeItem(at: file)
                removed += 1
            }
        }

        if let legacyFiles = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory, includingPropertiesForKeys: nil
        ) {
            for file in legacyFiles {
                let name = file.lastPathComponent
                guard name.hasSuffix(".wav"), legacyPrefixes.contains(where: name.hasPrefix) else {
                    continue
                }
                try? fileManager.removeItem(at: file)
                removed += 1
            }
        }

        if removed > 0 {
            SapoLog.recording.info("Temp audio sweep removed=\(removed, privacy: .public)")
        }
    }
}
