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
nonisolated enum TemporaryAudioStorage {
    /// Files older than this are considered abandoned by the launch sweep.
    private static let staleAge: TimeInterval = 24 * 60 * 60

    @MainActor private static var dailySweepTimer: Timer?

    /// R5: the app is resident for days — repeat the stale sweep daily so
    /// abandoned temp WAVs cannot pile up between launches.
    @MainActor static func startDailySweep() {
        guard dailySweepTimer == nil else { return }

        let timer = Timer(timeInterval: 86_400, repeats: true) { _ in
            Task.detached(priority: .utility) {
                sweepStaleFiles(referencedNames: historyReferencedNames())
            }
        }
        timer.tolerance = 3_600
        RunLoop.main.add(timer, forMode: .common)
        dailySweepTimer = timer
    }

    /// Prefixes of WAVs that older app versions wrote to the shared temp dir.
    private static let legacyPrefixes = [
        "recording_", "flux_recording_", "mic_test_raw_", "mic_test_compressed_",
    ]

    static var directory: URL { AppRuntimePaths.temporaryAudio }

    /// Returns a fresh UUID-named WAV URL, creating the directory if needed.
    static func makeWAVURL(prefix: String) -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Raw voice audio: owner-only, same policy as the history store.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("\(prefix)_\(UUID().uuidString).wav")
    }

    /// Last-path-component names of the audio History still points at, or nil
    /// when the scan was truncated. A row whose History copy failed points at
    /// the temp WAV, so a truncated scan would read as "nothing is referenced".
    static func historyReferencedNames() -> Set<String>? {
        TranscriptionHistoryManager.shared.referencedAudioPathsIfComplete().map { paths in
            Set(paths.map { ($0 as NSString).lastPathComponent })
        }
    }

    /// Removes temp WAVs older than 24h plus legacy timestamp-named WAVs that
    /// previous versions left in the shared system temp directory. Files named
    /// in `referencedNames` belong to a History row and are never swept; a nil
    /// set means the reference scan failed and nothing may be deleted.
    static func sweepStaleFiles(now: Date = Date(), referencedNames: Set<String>?) {
        var removed = sweepStaleFiles(in: directory, now: now, referencedNames: referencedNames)
        if !AppRuntimePaths.isIsolated {
            removed += sweepStaleFiles(
                in: FileManager.default.temporaryDirectory,
                now: now,
                referencedNames: referencedNames,
                legacyPrefixesOnly: true
            )
        }

        if removed > 0 {
            SapoLog.recording.info("Temp audio sweep removed=\(removed, privacy: .public)")
        }
    }

    @discardableResult
    static func sweepStaleFiles(
        in directory: URL,
        now: Date = Date(),
        referencedNames: Set<String>?,
        legacyPrefixesOnly: Bool = false
    ) -> Int {
        guard let referencedNames else {
            SapoLog.recording.error("failure=TempAudio/staleSweep detail=incomplete-reference-scan")
            return 0
        }
        let fileManager = FileManager.default
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return 0 }

        var removed = 0
        for file in files {
            let name = file.lastPathComponent
            if file.pathExtension == ActiveRecordingMarker.markerExtension {
                continue
            }
            if fileManager.fileExists(atPath: ActiveRecordingMarker.markerURL(for: file).path) {
                continue
            }
            if legacyPrefixesOnly {
                guard name.hasSuffix(".wav"), legacyPrefixes.contains(where: name.hasPrefix) else { continue }
            }
            guard !referencedNames.contains(name) else { continue }
            // A crash mid-write must not have its still-recoverable WAV deleted.
            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > staleAge else { continue }
            try? fileManager.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
