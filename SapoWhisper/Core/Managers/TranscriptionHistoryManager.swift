//
//  TranscriptionHistoryManager.swift
//  SapoWhisper
//

import Foundation
import SQLite3

/// Manages transcription history using SQLite
/// DB at ~/Library/Application Support/SapoWhisper/history.db
class TranscriptionHistoryManager {

    static let shared = TranscriptionHistoryManager()

    private var db: OpaquePointer?
    private let audioDir: URL

    // Max audio storage limit
    private static let maxAudioStorageBytes: Int64 = 500 * 1024 * 1024 // 500 MB

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        audioDir = appDir.appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let dbPath = appDir.appendingPathComponent("history.db").path
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            createTable()
            print("History DB opened: \(dbPath)")
        } else {
            print("Failed to open history DB")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS transcriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            engine TEXT NOT NULL,
            language TEXT NOT NULL,
            duration_seconds REAL NOT NULL,
            transcription TEXT NOT NULL,
            audio_path TEXT,
            status TEXT NOT NULL DEFAULT 'completed'
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Safely bind a Swift String to a SQLite statement parameter.
    /// Uses strdup so SQLite owns a copy — avoids PAC crash from unsafeBitCast SQLITE_TRANSIENT.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let cStr = strdup(value)
        sqlite3_bind_text(stmt, index, cStr, -1, { ptr in free(ptr) })
    }

    // MARK: - CRUD

    /// Save a transcription entry. Returns the row ID.
    @discardableResult
    func save(engine: String, language: String, duration: TimeInterval, text: String, audioPath: String? = nil, status: String = "completed") -> Int64 {
        let sql = "INSERT INTO transcriptions (timestamp, engine, language, duration_seconds, transcription, audio_path, status) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }

        let iso = ISO8601DateFormatter().string(from: Date())
        bindText(stmt, 1, iso)
        bindText(stmt, 2, engine)
        bindText(stmt, 3, language)
        sqlite3_bind_double(stmt, 4, duration)
        bindText(stmt, 5, text)
        if let path = audioPath {
            bindText(stmt, 6, path)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, status)

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    /// Save an audio file to the audio directory. Returns the saved path.
    func saveAudioFile(from sourceURL: URL) -> String? {
        let currentSize = audioDirectorySize()
        if currentSize > Self.maxAudioStorageBytes {
            cleanupOldAudio(olderThanDays: 1)
        }

        let filename = "audio_\(Date().timeIntervalSince1970).wav"
        let destURL = audioDir.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL.path
        } catch {
            print("Failed to save audio: \(error)")
            return nil
        }
    }

    /// Update status of a transcription entry
    func updateStatus(id: Int64, status: String, transcription: String? = nil) {
        var sql = "UPDATE transcriptions SET status = ?"
        if transcription != nil { sql += ", transcription = ?" }
        sql += " WHERE id = ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, 1, status)
        if let text = transcription {
            bindText(stmt, 2, text)
            sqlite3_bind_int64(stmt, 3, id)
        } else {
            sqlite3_bind_int64(stmt, 2, id)
        }
        sqlite3_step(stmt)
    }

    /// Clean up audio files older than `days`
    func cleanupOldAudio(olderThanDays days: Int = 7) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let iso = ISO8601DateFormatter().string(from: cutoff)

        // 1. Collect audio paths first
        var pathsToDelete: [String] = []
        let selectSql = "SELECT audio_path FROM transcriptions WHERE timestamp < ? AND audio_path IS NOT NULL;"
        var selectStmt: OpaquePointer?
        defer { sqlite3_finalize(selectStmt) }
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return }
        bindText(selectStmt, 1, iso)
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(selectStmt, 0) {
                pathsToDelete.append(String(cString: cStr))
            }
        }

        // 2. Delete DB entries
        let deleteSql = "DELETE FROM transcriptions WHERE timestamp < ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        bindText(deleteStmt, 1, iso)
        sqlite3_step(deleteStmt)

        // 3. Delete audio files (after DB is clean)
        for path in pathsToDelete {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func audioDirectorySize() -> Int64 {
        let enumerator = FileManager.default.enumerator(at: audioDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0
        }
        return total
    }
}
