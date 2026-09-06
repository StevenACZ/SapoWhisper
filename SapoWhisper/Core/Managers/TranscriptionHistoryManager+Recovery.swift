import Foundation
import SQLite3

nonisolated extension TranscriptionHistoryManager {
    func latestResumableDictation(now: Date = Date()) -> ResumableDictation? {
        let window = ResumableDictation.lifetime
        let sql = """
            SELECT id, audio_path, duration_seconds, timestamp FROM transcriptions
            WHERE status = 'failed' AND audio_path IS NOT NULL AND audio_path != ''
                AND timestamp > ? AND timestamp <= ?
                AND (failure_code GLOB ? OR failure_code GLOB ? OR failure_code IN (?, ?) OR failure_code GLOB ?)
            ORDER BY timestamp DESC, id DESC;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, Self.isoFormatter.string(from: now.addingTimeInterval(-window)))
        bindText(statement, 2, Self.isoFormatter.string(from: now))
        bindText(statement, 3, "*/\(TranscriptionFailure.Kind.userCancelled.rawValue)")
        bindText(statement, 4, "*/\(TranscriptionFailure.Kind.recordingInterrupted.rawValue)")
        bindText(statement, 5, OrphanAudioRecovery.failureCode)
        bindText(statement, 6, Self.interruptedTranscriptionFailureCode)
        bindText(statement, 7, "*/\(TranscriptionFailure.Kind.audioStorageFailed.rawValue)")

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let audioPath = sqlite3_column_text(statement, 1),
                let timestamp = sqlite3_column_text(statement, 3),
                let capturedAt = Self.isoFormatter.date(from: String(cString: timestamp)),
                now.timeIntervalSince(capturedAt) < window
            else { continue }
            let audioURL = URL(fileURLWithPath: String(cString: audioPath))
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            return ResumableDictation(
                historyId: sqlite3_column_int64(statement, 0),
                audioURL: audioURL,
                duration: sqlite3_column_double(statement, 2),
                capturedAt: capturedAt
            )
        }
        return nil
    }
}
