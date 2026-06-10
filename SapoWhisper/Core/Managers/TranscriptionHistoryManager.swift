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

    private convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("SapoWhisper")
        self.init(
            databasePath: appDir.appendingPathComponent("history.db").path,
            audioDirectory: appDir
        )
    }

    /// Designated initializer; tests pass `:memory:` and a temp audio dir.
    init(databasePath: String, audioDirectory: URL) {
        audioStorage = HistoryAudioStorage(appDirectory: audioDirectory)

        // FULLMUTEX: history persistence runs off the paste path (background
        // task) while the UI reads from the main thread on this connection.
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databasePath, &db, openFlags, nil) == SQLITE_OK {
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
        // History UI observers expect main-thread delivery; saves may post
        // from the background persistence task.
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    /// Steps a mutating statement and surfaces SQLite errors in diagnostics
    /// instead of failing silently. Returns true on SQLITE_DONE.
    @discardableResult
    func stepStatement(_ stmt: OpaquePointer?, operation: String) -> Bool {
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE else {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            SapoLog.recording.error(
                "failure=History/\(operation, privacy: .public) code=\(result, privacy: .public) detail=\(message, privacy: .public)"
            )
            return false
        }
        return true
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
        aiError: String? = nil,
        failureCode: String? = nil
    ) -> Int64 {
        let sql =
            """
            INSERT INTO transcriptions (
                timestamp, engine, language, duration_seconds, transcription, raw_transcription,
                audio_path, status, ai_status, ai_model, ai_mode, ai_error, failure_code
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        if let failureCode {
            bindText(stmt, 13, failureCode)
        } else {
            sqlite3_bind_null(stmt, 13)
        }

        guard stepStatement(stmt, operation: "save") else { return -1 }
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
        stepStatement(stmt, operation: "updateStatus")
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
        // H10: SET expressions read the row's pre-update values, so the first
        // applied polish is archived into ai_first_* before being overwritten.
        let sql = """
            UPDATE transcriptions
            SET ai_first_status = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_status ELSE ai_first_status END,
                ai_first_model = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_model ELSE ai_first_model END,
                ai_first_mode = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_mode ELSE ai_first_mode END,
                transcription = ?, raw_transcription = ?, ai_status = ?, ai_model = ?, ai_mode = ?, ai_error = ?, status = 'completed'
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
        stepStatement(stmt, operation: "updateAIProcessing")
        notifyDidChange()
    }

    /// Applies a retranscription onto the original row instead of inserting a
    /// duplicate. The first engine is preserved in original_engine for audit.
    func updateRetranscription(
        id: Int64,
        engine: String,
        finalText: String,
        rawText: String,
        aiStatus: TranscriptAIStatus,
        aiModel: String?,
        aiMode: String?,
        aiError: String?
    ) {
        let sql = """
            UPDATE transcriptions
            SET original_engine = COALESCE(original_engine, engine), engine = ?,
                ai_first_status = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_status ELSE ai_first_status END,
                ai_first_model = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_model ELSE ai_first_model END,
                ai_first_mode = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_mode ELSE ai_first_mode END,
                transcription = ?, raw_transcription = ?, ai_status = ?, ai_model = ?, ai_mode = ?,
                ai_error = ?, status = 'completed'
            WHERE id = ?;
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }

        bindText(stmt, 1, engine)
        bindText(stmt, 2, finalText)
        bindText(stmt, 3, rawText)
        bindText(stmt, 4, aiStatus.rawValue)
        if let aiModel {
            bindText(stmt, 5, aiModel)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let aiMode {
            bindText(stmt, 6, aiMode)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let aiError {
            bindText(stmt, 7, aiError)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_bind_int64(stmt, 8, id)
        stepStatement(stmt, operation: "updateRetranscription")
        notifyDidChange()
    }
}
