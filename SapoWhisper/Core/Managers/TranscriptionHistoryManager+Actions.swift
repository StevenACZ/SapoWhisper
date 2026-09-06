//
//  TranscriptionHistoryManager+Actions.swift
//  SapoWhisper
//

import Foundation
import SQLite3
import os

nonisolated extension TranscriptionHistoryManager {
    /// Pre-persisted row whose engine is still running. Its History audio is
    /// the only copy of the in-flight dictation, so no delete path may remove
    /// it before the pipeline (or the launch sweep) resolves the row.
    static let processingSQLValues = HistoryEntryStatus.processingSQLValues

    /// H5: delete entries (and their audio) older than `days`, keeping pinned
    /// rows and rows still being transcribed. Returns the number of deleted
    /// rows.
    @discardableResult
    func deleteEntries(olderThanDays days: Int) -> Int {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return 0 }
        let iso = Self.isoFormatter.string(from: cutoff)

        let deleteSql =
            "DELETE FROM transcriptions WHERE timestamp < ? AND is_favorite = 0 AND status = 'completed' AND (retention_until IS NULL OR retention_until <= ?);"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return 0 }
        bindText(deleteStmt, 1, iso)
        bindText(deleteStmt, 2, Self.isoFormatter.string(from: Date()))
        guard stepStatement(deleteStmt, operation: "deleteOlderThan") else { return 0 }
        let deleted = Int(sqlite3_changes(db))

        // Pinned and in-flight rows survive the DELETE: sweep only audio that
        // lost its row.
        sweepOrphanedAudio()
        deleteOrphanedPolishVersions()

        notifyDidChange()
        return deleted
    }

    /// H5: clear the whole history (audio included), except rows still being
    /// transcribed. Returns the row count.
    @discardableResult
    func deleteAll() -> Int {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let paths = deletableAudioPaths()

        let deleteSql = "DELETE FROM transcriptions WHERE status NOT IN \(Self.processingSQLValues);"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return 0 }
        guard stepStatement(deleteStmt, operation: "deleteAll") else { return 0 }
        let deleted = Int(sqlite3_changes(db))

        for path in paths {
            audioStorage.deleteAudioFile(at: path)
        }
        deleteOrphanedPolishVersions()

        notifyDidChange()
        return deleted
    }

    func enforceAudioStorageLimit() {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard sweepOrphanedAudio() else { return }
        guard audioStorage.directorySize() > HistoryAudioStorage.maxAudioStorageBytes else { return }

        deleteOldestEntriesWithAudio()
        if audioStorage.directorySize() > HistoryAudioStorage.maxAudioStorageBytes {
            SapoLog.recording.warning("History audio limit exceeded; protected recordings retained")
        }
    }

    /// A truncated reference scan makes live recordings look orphaned, so it
    /// aborts the sweep (and the size trim behind it) instead of deleting.
    /// Returns false when the sweep was skipped.
    @discardableResult
    private func sweepOrphanedAudio() -> Bool {
        guard let referencedPaths = referencedAudioPathsIfComplete() else {
            SapoLog.recording.error("failure=History/orphanSweep detail=incomplete-reference-scan")
            return false
        }
        audioStorage.deleteOrphanedAudioFiles(referencedPaths: referencedPaths)
        return true
    }

    @discardableResult
    func extendRetention(id: Int64, days: Int = 30, now: Date = Date()) -> Bool {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard (1...3650).contains(days), let entry = entry(id: id) else { return false }
        let autoDeleteDays = AppPreferences.defaults.integer(forKey: Constants.StorageKeys.historyAutoDeleteDays)
        let base = max(max(now, entry.retentionUntil ?? now), entry.retentionDeadline(autoDeleteDays: autoDeleteDays) ?? now)
        guard let deadline = Calendar.current.date(byAdding: .day, value: days, to: base) else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "UPDATE transcriptions SET retention_until = ? WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        bindText(stmt, 1, Self.isoFormatter.string(from: deadline))
        sqlite3_bind_int64(stmt, 2, id)
        guard stepStatement(stmt, operation: "extendRetention"), sqlite3_changes(db) == 1 else { return false }
        notifyDidChange()
        return true
    }

    /// Toggle the favorite status of an entry. Returns new state.
    @discardableResult
    func toggleFavorite(id: Int64) -> Bool {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let updateSql = "UPDATE transcriptions SET is_favorite = CASE WHEN is_favorite = 0 THEN 1 ELSE 0 END WHERE id = ?;"
        var updateStmt: OpaquePointer?
        defer { sqlite3_finalize(updateStmt) }
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(updateStmt, 1, id)
        guard stepStatement(updateStmt, operation: "toggleFavorite") else { return false }

        let selectSql = "SELECT is_favorite FROM transcriptions WHERE id = ?;"
        var selectStmt: OpaquePointer?
        defer { sqlite3_finalize(selectStmt) }
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(selectStmt, 1, id)
        guard sqlite3_step(selectStmt) == SQLITE_ROW else { return false }

        let newState = sqlite3_column_int(selectStmt, 0) != 0
        notifyDidChange()
        return newState
    }

    /// Delete a transcription entry and its audio file. A row still being
    /// transcribed is refused, and its audio only goes once the row is gone.
    func delete(id: Int64) {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let audioPath = audioPath(for: id)
        let deleteSql = "DELETE FROM transcriptions WHERE id = ? AND status NOT IN \(Self.processingSQLValues);"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(deleteStmt, 1, id)
        guard stepStatement(deleteStmt, operation: "delete"), sqlite3_changes(db) > 0 else { return }

        if let audioPath {
            audioStorage.deleteAudioFile(at: audioPath)
        }
        deleteOrphanedPolishVersions()

        notifyDidChange()
    }

    private func deleteOldestEntriesWithAudio() {
        for row in oldestAudioRows() {
            guard audioStorage.directorySize() > HistoryAudioStorage.targetAudioStorageBytes else { break }
            delete(id: row.id)
        }
    }

    private func oldestAudioRows() -> [(id: Int64, path: String)] {
        let sql = """
            SELECT id, audio_path FROM transcriptions
            WHERE audio_path IS NOT NULL AND is_favorite = 0 AND status = 'completed'
              AND (retention_until IS NULL OR retention_until <= ?)
              AND id != (SELECT id FROM transcriptions ORDER BY timestamp DESC, id DESC LIMIT 1)
            ORDER BY timestamp ASC;
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        bindText(stmt, 1, Self.isoFormatter.string(from: Date()))
        var rows: [(Int64, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 1) else { continue }
            rows.append((sqlite3_column_int64(stmt, 0), String(cString: cString)))
        }
        return rows
    }

    /// Audio referenced only by rows `deleteAll` is allowed to remove, so the
    /// in-flight take keeps its file.
    private func deletableAudioPaths() -> Set<String> {
        let sql = "SELECT audio_path FROM transcriptions WHERE audio_path IS NOT NULL AND status NOT IN \(Self.processingSQLValues);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        var paths = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                paths.insert(String(cString: cString))
            }
        }
        return paths
    }

    private func audioPath(for id: Int64) -> String? {
        let selectSql = "SELECT audio_path FROM transcriptions WHERE id = ?;"
        var selectStmt: OpaquePointer?
        defer { sqlite3_finalize(selectStmt) }
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(selectStmt, 1, id)

        guard sqlite3_step(selectStmt) == SQLITE_ROW,
            sqlite3_column_type(selectStmt, 0) != SQLITE_NULL,
            let cString = sqlite3_column_text(selectStmt, 0)
        else {
            return nil
        }

        return String(cString: cString)
    }
}

nonisolated extension HistoryEntry {
    /// Mirrors the guard `delete(id:)` and `deleteAll()` enforce in SQL, so the
    /// UI can disable a delete instead of silently no-opping it.
    var isDeletable: Bool {
        !isProcessing
    }
}
