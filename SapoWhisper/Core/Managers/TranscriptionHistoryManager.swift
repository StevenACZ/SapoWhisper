//
//  TranscriptionHistoryManager.swift
//  SapoWhisper
//

import Foundation
import SQLite3
import os

/// Manages transcription history using SQLite
/// DB at ~/Library/Application Support/SapoWhisper/history.db
///
/// Thread-safety: the connection opens with FULLMUTEX and every operation
/// prepares its own statement, so calls are safe from any thread — the UI
/// reads on main while persistence runs on background tasks (L3). UI change
/// notifications always post on main via `notifyDidChange`.
nonisolated class TranscriptionHistoryManager: @unchecked Sendable {

    static let shared = TranscriptionHistoryManager()
    static let didChangeNotification = Notification.Name("TranscriptionHistoryManager.didChange")
    // nonisolated(unsafe): ISO8601DateFormatter is documented thread-safe.
    static nonisolated(unsafe) let isoFormatter = ISO8601DateFormatter()

    var db: OpaquePointer?
    let audioStorage: HistoryAudioStorage

    /// Serializes audio+DB mutations (persist / insert / delete / orphan sweep)
    /// so a concurrent save's orphan sweep cannot delete a just-copied WAV
    /// before its row references it (silent audio-loss race). Recursive because
    /// `save -> enforceAudioStorageLimit -> deleteOldestEntriesWithAudio ->
    /// delete(id:)` re-enters on a single thread. Every path that copies,
    /// sweeps, or deletes audio must hold it; read-only queries stay on
    /// FULLMUTEX only.
    let persistenceLock = NSRecursiveLock()

    private convenience init() {
        let appDir = AppRuntimePaths.applicationSupport
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
        if sqlite3_open_v2(databasePath, &db, openFlags, nil) == SQLITE_OK, integrityCheckPasses() {
            configureDatabase()
            createTable()
            migrateSchema()
            createIndexes()
            SapoLog.recording.info("History DB opened")
        } else {
            // A corrupt or unopenable file otherwise no-ops every later call
            // and History dies silently forever.
            recoverCorruptDatabase(at: databasePath, openFlags: openFlags)
        }
    }

    /// Cheap `PRAGMA integrity_check(1)` at open time; anything but "ok"
    /// routes through corruption recovery.
    private func integrityCheckPasses() -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check(1)", -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW,
            let cString = sqlite3_column_text(stmt, 0)
        else { return false }
        return String(cString: cString).lowercased() == "ok"
    }

    /// Sidelines the corrupt file (plus WAL/SHM) and the audio it referenced
    /// with a timestamp, then recreates a fresh schema — dictation keeps
    /// persisting and the evidence stays on disk for inspection.
    private func recoverCorruptDatabase(at databasePath: String, openFlags: Int32) {
        sqlite3_close(db)
        db = nil
        guard databasePath != ":memory:" else {
            SapoLog.recording.error("Failed to open in-memory history DB")
            return
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = databasePath + suffix
            guard fileManager.fileExists(atPath: source) else { continue }
            try? fileManager.moveItem(
                atPath: source, toPath: databasePath + ".corrupt-\(stamp)" + suffix)
        }
        SapoLog.recording.error("History DB corrupt or unopenable; sidelined stamp=\(stamp, privacy: .public)")
        // The fresh schema references no audio, so the first orphan sweep would
        // delete every recording the lost rows pointed at.
        audioStorage.sidelineAll(stamp: stamp)

        if sqlite3_open_v2(databasePath, &db, openFlags, nil) == SQLITE_OK {
            configureDatabase()
            createTable()
            migrateSchema()
            createIndexes()
            SapoLog.recording.info("History DB recreated after corruption")
        } else {
            sqlite3_close(db)
            db = nil
            SapoLog.recording.error("Failed to recreate history DB after corruption")
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
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
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
        if aiStatus == TranscriptAIStatus.applied.rawValue {
            insertPolishVersion(entryId: rowID, model: aiModel, text: text)
        }
        enforceAudioStorageLimit()
        notifyDidChange()
        return rowID
    }

    /// Appends one row to the entry's polish trail. Called from every write
    /// path that lands an applied polish, so the trail and the ai_* columns
    /// can never drift apart.
    func insertPolishVersion(entryId: Int64, model: String?, text: String) {
        guard !text.isEmpty else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let sql = """
            INSERT INTO polish_versions (entry_id, created_at, model, text)
            SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM transcriptions WHERE id = ?);
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(stmt, 1, entryId)
        bindText(stmt, 2, Self.isoFormatter.string(from: Date()))
        if let model {
            bindText(stmt, 3, model)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindText(stmt, 4, text)
        sqlite3_bind_int64(stmt, 5, entryId)
        stepStatement(stmt, operation: "insertPolishVersion")
    }

    /// polish_versions has no FK cascade (the table arrived after the schema
    /// settled); every delete path sweeps rows whose entry is gone.
    func deleteOrphanedPolishVersions() {
        let sql = "DELETE FROM polish_versions WHERE entry_id NOT IN (SELECT id FROM transcriptions);"
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Atomically copies the source audio into history storage and inserts its
    /// row under `persistenceLock`. Holding the lock across copy + insert +
    /// orphan sweep is what prevents a concurrent save's sweep from deleting the
    /// freshly copied WAV before its row references it. Callers must persist
    /// audio through this method, never via a separate copy + `save`.
    @discardableResult
    func persistEntry(
        audioSource: URL?,
        engine: String,
        language: String,
        duration: TimeInterval,
        text: String,
        rawText: String? = nil,
        status: String = "completed",
        aiStatus: String = TranscriptAIStatus.none.rawValue,
        aiModel: String? = nil,
        aiMode: String? = nil,
        aiError: String? = nil,
        failureCode: String? = nil
    ) -> (rowID: Int64, audioPath: String?, copiedToHistory: Bool) {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }

        let savedPath = audioSource.flatMap { audioStorage.saveAudioFile(from: $0) }
        let fallbackPath = audioSource.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
        }
        let audioPath = savedPath ?? fallbackPath

        let rowID = save(
            engine: engine,
            language: language,
            duration: duration,
            text: text,
            rawText: rawText,
            audioPath: audioPath,
            status: status,
            aiStatus: aiStatus,
            aiModel: aiModel,
            aiMode: aiMode,
            aiError: aiError,
            failureCode: failureCode
        )

        // The copy + insert pair is not atomic against insert failure: when the
        // insert fails, roll back the copied file and fall back to the source
        // WAV so the retry path still has audio.
        if rowID < 0, let savedPath {
            audioStorage.deleteAudioFile(at: savedPath)
            return (rowID, fallbackPath, false)
        }
        return (rowID, audioPath, savedPath != nil)
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

    /// Resolves a pre-persisted "transcribing" row (or any row) into a failed
    /// one, keeping its History audio retranscribable.
    func markTranscriptionFailed(id: Int64, failureCode: String) {
        let sql = "UPDATE transcriptions SET status = 'failed', failure_code = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, 1, failureCode)
        sqlite3_bind_int64(stmt, 2, id)
        stepStatement(stmt, operation: "markTranscriptionFailed")
        notifyDidChange()
    }

    /// A dictation whose app died mid-transcription: its row was pre-persisted
    /// as "transcribing" and never resolved.
    struct InterruptedTranscription {
        let id: Int64
        let audioPath: String?
        let duration: TimeInterval
        let timestamp: Date
    }

    static let interruptedTranscriptionFailureCode = "SapoWhisper/interrupted_transcription"

    /// Launch sweep: rows stuck in "transcribing" belong to a session that died
    /// mid-transcription (crash, force-quit, power loss). Their audio already
    /// lives in History storage, so each becomes a failed row the user can
    /// retranscribe. Returns the most recent one as the "continue previous
    /// dictation" offer candidate.
    @discardableResult
    func recoverInterruptedTranscriptions() -> InterruptedTranscription? {
        let sql = """
            SELECT id, audio_path, duration_seconds, timestamp FROM transcriptions
            WHERE status IN \(HistoryEntryStatus.processingSQLValues) ORDER BY timestamp DESC, id DESC;
            """
        var stmt: OpaquePointer?
        var interrupted: [InterruptedTranscription] = []
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let audioPath: String? =
                sqlite3_column_type(stmt, 1) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 1)) : nil
            let timestampStr = String(cString: sqlite3_column_text(stmt, 3))
            interrupted.append(
                InterruptedTranscription(
                    id: sqlite3_column_int64(stmt, 0),
                    audioPath: audioPath,
                    duration: sqlite3_column_double(stmt, 2),
                    timestamp: Self.isoFormatter.date(from: timestampStr) ?? Date()
                )
            )
        }
        guard !interrupted.isEmpty else { return nil }
        for row in interrupted {
            markTranscriptionFailed(id: row.id, failureCode: Self.interruptedTranscriptionFailureCode)
        }
        SapoLog.recording.info(
            "Interrupted transcriptions recovered rows=\(interrupted.count, privacy: .public)"
        )
        return interrupted.first
    }

    /// True when `url` lives inside History's permanent audio directory —
    /// files History owns must never be deleted by temp/stale cleanup paths.
    func ownsAudioFile(at url: URL) -> Bool {
        audioStorage.ownsFile(at: url)
    }

    func markProcessingStage(id: Int64, stage: HistoryEntryStatus, rawText: String? = nil) {
        guard stage.isProcessing else { return }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let sql = """
            UPDATE transcriptions SET status = ?,
                raw_transcription = COALESCE(?, raw_transcription),
                transcription = CASE WHEN transcription = '' THEN COALESCE(?, transcription) ELSE transcription END
            WHERE id = ? AND status IN \(HistoryEntryStatus.processingSQLValues);
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bindText(statement, 1, stage.rawValue)
        if let rawText {
            bindText(statement, 2, rawText)
            bindText(statement, 3, rawText)
        } else {
            sqlite3_bind_null(statement, 2)
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, id)
        guard stepStatement(statement, operation: "markProcessingStage"), sqlite3_changes(db) > 0 else { return }
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
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        // H10: SET expressions read the row's pre-update values, so the first
        // applied polish is archived into ai_first_* before being overwritten.
        let sql = """
            UPDATE transcriptions
            SET ai_first_status = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_status ELSE ai_first_status END,
                ai_first_model = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_model ELSE ai_first_model END,
                ai_first_mode = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_mode ELSE ai_first_mode END,
                transcription = ?, raw_transcription = ?, ai_status = ?, ai_model = ?, ai_mode = ?, ai_error = ?,
                status = 'completed', failure_code = NULL
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
        guard stepStatement(stmt, operation: "updateAIProcessing"), sqlite3_changes(db) == 1 else { return }
        if aiStatus == .applied {
            insertPolishVersion(entryId: id, model: aiModel, text: finalText)
        }
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
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let sql = """
            UPDATE transcriptions
            SET original_engine = COALESCE(original_engine, engine), engine = ?,
                ai_first_status = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_status ELSE ai_first_status END,
                ai_first_model = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_model ELSE ai_first_model END,
                ai_first_mode = CASE WHEN ai_first_status IS NULL AND ai_status != 'none' THEN ai_mode ELSE ai_first_mode END,
                transcription = ?, raw_transcription = ?, ai_status = ?, ai_model = ?, ai_mode = ?,
                ai_error = ?, status = 'completed', failure_code = NULL
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
        guard stepStatement(stmt, operation: "updateRetranscription"), sqlite3_changes(db) == 1 else { return }
        if aiStatus == .applied {
            insertPolishVersion(entryId: id, model: aiModel, text: finalText)
        }
        notifyDidChange()
    }
}
