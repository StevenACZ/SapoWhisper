//
//  TranscriptionHistoryManager.swift
//  SapoWhisper
//

import Foundation
import SQLite3
import os

/// Manages transcription history using SQLite
/// DB at ~/Library/Application Support/SapoWhisper/history.db
class TranscriptionHistoryManager {

    static let shared = TranscriptionHistoryManager()
    static let didChangeNotification = Notification.Name("TranscriptionHistoryManager.didChange")
    static let isoFormatter = ISO8601DateFormatter()

    var db: OpaquePointer?
    let audioStorage: HistoryAudioStorage

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        audioStorage = HistoryAudioStorage(appDirectory: appDir)

        let dbPath = appDir.appendingPathComponent("history.db").path
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            configureDatabase()
            createTable()
            migrateSchema()
            createIndexes()
            SapoLog.recording.info("History DB opened")
        } else {
            SapoLog.recording.error("Failed to open history DB")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Safely bind a Swift String to a SQLite statement parameter.
    /// Uses strdup so SQLite owns a copy — avoids PAC crash from unsafeBitCast SQLITE_TRANSIENT.
    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let cStr = strdup(value)
        sqlite3_bind_text(stmt, index, cStr, -1, { ptr in free(ptr) })
    }

    func notifyDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - CRUD

    /// Save a transcription entry. Returns the row ID.
    @discardableResult
    func save(
        engine: String,
        language: String,
        duration: TimeInterval,
        text: String,
        rawText: String? = nil,
        audioPath: String? = nil,
        status: String = "completed",
        aiStatus: String = TranscriptAIStatus.none.rawValue,
        aiModel: String? = nil,
        aiMode: String? = nil,
        aiError: String? = nil
    ) -> Int64 {
        let sql =
            """
            INSERT INTO transcriptions (
                timestamp, engine, language, duration_seconds, transcription, raw_transcription,
                audio_path, status, ai_status, ai_model, ai_mode, ai_error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }

        let iso = Self.isoFormatter.string(from: Date())
        bindText(stmt, 1, iso)
        bindText(stmt, 2, engine)
        bindText(stmt, 3, language)
        sqlite3_bind_double(stmt, 4, duration)
        bindText(stmt, 5, text)
        bindText(stmt, 6, rawText ?? text)
        if let path = audioPath {
            bindText(stmt, 7, path)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bindText(stmt, 8, status)
        bindText(stmt, 9, aiStatus)
        if let aiModel {
            bindText(stmt, 10, aiModel)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        if let aiMode {
            bindText(stmt, 11, aiMode)
        } else {
            sqlite3_bind_null(stmt, 11)
        }
        if let aiError {
            bindText(stmt, 12, aiError)
        } else {
            sqlite3_bind_null(stmt, 12)
        }

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else { return -1 }
        let rowID = sqlite3_last_insert_rowid(db)
        enforceAudioStorageLimit()
        notifyDidChange()
        return rowID
    }

    /// Save an audio file to the audio directory. Returns the saved path.
    func saveAudioFile(from sourceURL: URL) -> String? {
        audioStorage.saveAudioFile(from: sourceURL)
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
        notifyDidChange()
    }

    func updateAIProcessing(
        id: Int64,
        finalText: String,
        rawText: String,
        aiStatus: TranscriptAIStatus,
        aiModel: String?,
        aiMode: String?,
        aiError: String?
    ) {
        let sql = """
            UPDATE transcriptions
            SET transcription = ?, raw_transcription = ?, ai_status = ?, ai_model = ?, ai_mode = ?, ai_error = ?, status = 'completed'
            WHERE id = ?;
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, 1, finalText)
        bindText(stmt, 2, rawText)
        bindText(stmt, 3, aiStatus.rawValue)
        if let aiModel {
            bindText(stmt, 4, aiModel)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let aiMode {
            bindText(stmt, 5, aiMode)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let aiError {
            bindText(stmt, 6, aiError)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_int64(stmt, 7, id)
        sqlite3_step(stmt)
        notifyDidChange()
    }
}
