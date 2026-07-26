//
//  TranscriptionHistoryManager+Actions.swift
//  SapoWhisper
//

import Foundation
import SQLite3

nonisolated extension TranscriptionHistoryManager {
    /// Pre-persisted row whose engine is still running. Its History audio is
    /// the only copy of the in-flight dictation, so no delete path may remove
    /// it before the pipeline (or the launch sweep) resolves the row.
    static let inFlightStatus = "transcribing"

    /// H5: delete entries (and their audio) older than `days`, keeping pinned
    /// rows. Returns the number of deleted rows.
    @discardableResult
    func deleteEntries(olderThanDays days: Int) -> Int {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let iso = Self.isoFormatter.string(from: cutoff)

        let deleteSql = "DELETE FROM transcriptions WHERE timestamp < ? AND is_favorite = 0;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return 0 }
        bindText(deleteStmt, 1, iso)
        guard stepStatement(deleteStmt, operation: "deleteOlderThan") else { return 0 }
        let deleted = Int(sqlite3_changes(db))

        // Pinned rows survive the DELETE: sweep only audio that lost its row.
        audioStorage.deleteOrphanedAudioFiles(referencedPaths: referencedAudioPaths())
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

        let deleteSql = "DELETE FROM transcriptions WHERE status != ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return 0 }
        bindText(deleteStmt, 1, Self.inFlightStatus)
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
        audioStorage.deleteOrphanedAudioFiles(referencedPaths: referencedAudioPaths())
        guard audioStorage.directorySize() > HistoryAudioStorage.maxAudioStorageBytes else { return }

        deleteOldestEntriesWithAudio(includeFavorites: false)
        if audioStorage.directorySize() > HistoryAudioStorage.maxAudioStorageBytes {
            deleteOldestEntriesWithAudio(includeFavorites: true)
        }
    }

    /// Toggle the favorite status of an entry. Returns new state.
    @discardableResult
    func toggleFavorite(id: Int64) -> Bool {
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
        let deleteSql = "DELETE FROM transcriptions WHERE id = ? AND status != ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(deleteStmt, 1, id)
        bindText(deleteStmt, 2, Self.inFlightStatus)
        guard stepStatement(deleteStmt, operation: "delete"), sqlite3_changes(db) > 0 else { return }

        if let audioPath {
            audioStorage.deleteAudioFile(at: audioPath)
        }
        deleteOrphanedPolishVersions()

        notifyDidChange()
    }

    private func deleteOldestEntriesWithAudio(includeFavorites: Bool) {
        for row in oldestAudioRows(includeFavorites: includeFavorites) {
            guard audioStorage.directorySize() > HistoryAudioStorage.targetAudioStorageBytes else { break }
            delete(id: row.id)
        }
    }

    private func oldestAudioRows(includeFavorites: Bool) -> [(id: Int64, path: String)] {
        var sql = "SELECT id, audio_path FROM transcriptions WHERE audio_path IS NOT NULL"
        if !includeFavorites {
            sql += " AND is_favorite = 0"
        }
        sql += " ORDER BY timestamp ASC;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

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
        let sql = "SELECT audio_path FROM transcriptions WHERE audio_path IS NOT NULL AND status != ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, Self.inFlightStatus)

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
        status != TranscriptionHistoryManager.inFlightStatus
    }
}
