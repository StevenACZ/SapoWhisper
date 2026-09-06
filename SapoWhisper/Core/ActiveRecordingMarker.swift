//
//  ActiveRecordingMarker.swift
//  SapoWhisper
//

import Darwin
import Foundation
import os

/// Sidecar `<recording>.wav.active` files identifying which temp WAV belongs
/// to a live capture or a sealed streaming take not yet owned by History, and
/// which process owns it.
///
/// The launch orphan recovery used to wait 60 s of file age before adopting a
/// WAV, so a crash followed by an immediate relaunch left the dictation
/// invisible until the *next* launch. With the marker, a WAV whose owning PID
/// is dead is recoverable instantly — and one whose owner still runs is never
/// stolen from a live session.
nonisolated enum ActiveRecordingMarker {

    static let markerExtension = "active"

    static func markerURL(for recordingURL: URL) -> URL {
        recordingURL.appendingPathExtension(markerExtension)
    }

    /// Writes the marker for a capture that just opened its WAV. All
    /// captures retain it through sealing and processing; History
    /// persistence clears it only after a row safely references the audio.
    static func mark(_ recordingURL: URL) {
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try pid.write(to: markerURL(for: recordingURL), atomically: true, encoding: .utf8)
        } catch {
            let detail = TranscriptionFailure.diagnosticDetail(for: error)
            SapoLog.recording.warning(
                "Active-recording marker write failed error=\(detail, privacy: .public)"
            )
        }
    }

    /// Removes the marker once the capture finalized or was cleaned up.
    static func clear(_ recordingURL: URL) {
        try? FileManager.default.removeItem(at: markerURL(for: recordingURL))
    }

    /// True when the PID recorded in the marker still names a live process.
    /// `kill(pid, 0)` probes liveness without signalling; EPERM still means
    /// alive (owned by someone else), ESRCH means gone.
    static func ownerIsAlive(markerURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: markerURL, encoding: .utf8),
            let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// WAV URLs in `directory` whose marker exists but whose owner died —
    /// instantly recoverable. Markers remain until History owns the audio;
    /// only dead markers without a WAV are removed here.
    static func abandonedRecordings(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        var abandoned: [URL] = []
        for marker in files where marker.pathExtension == markerExtension {
            guard !ownerIsAlive(markerURL: marker) else { continue }

            let recordingURL = marker.deletingPathExtension()
            if fileManager.fileExists(atPath: recordingURL.path) {
                abandoned.append(recordingURL)
            } else {
                try? fileManager.removeItem(at: marker)
            }
        }
        return abandoned
    }
}
