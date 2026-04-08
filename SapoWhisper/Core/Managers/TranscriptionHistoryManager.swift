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
    static let didChangeNotification = Notification.Name("TranscriptionHistoryManager.didChange")
    private static let isoFormatter = ISO8601DateFormatter()
    private static let defaultFetchLimit = 250

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
            configureDatabase()
            createTable()
            migrateSchema()
            createIndexes()
            print("History DB opened: \(dbPath)")
        } else {
            print("Failed to open history DB")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrateSchema() {
        guard !columnExists(named: "is_favorite", in: "transcriptions") else { return }

        let sql = "ALTER TABLE transcriptions ADD COLUMN is_favorite INTEGER DEFAULT 0;"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            if let message = sqlite3_errmsg(db) {
                print("Failed to migrate history schema: \(String(cString: message))")
            }
        }
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
            status TEXT NOT NULL DEFAULT 'completed',
            is_favorite INTEGER NOT NULL DEFAULT 0
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func configureDatabase() {
        sqlite3_busy_timeout(db, 1000)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
    }

    private func createIndexes() {
        let statements = [
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_timestamp ON transcriptions(timestamp DESC);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_status ON transcriptions(status);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_favorite_timestamp ON transcriptions(is_favorite, timestamp DESC);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_engine_timestamp ON transcriptions(engine, timestamp DESC);"
        ]

        for statement in statements {
            sqlite3_exec(db, statement, nil, nil, nil)
        }
    }

    private func columnExists(named columnName: String, in tableName: String) -> Bool {
        let sql = "PRAGMA table_info(\(tableName));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: cString) == columnName {
                return true
            }
        }

        return false
    }

    /// Safely bind a Swift String to a SQLite statement parameter.
    /// Uses strdup so SQLite owns a copy — avoids PAC crash from unsafeBitCast SQLITE_TRANSIENT.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let cStr = strdup(value)
        sqlite3_bind_text(stmt, index, cStr, -1, { ptr in free(ptr) })
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - CRUD

    /// Save a transcription entry. Returns the row ID.
    @discardableResult
    func save(engine: String, language: String, duration: TimeInterval, text: String, audioPath: String? = nil, status: String = "completed") -> Int64 {
        let sql = "INSERT INTO transcriptions (timestamp, engine, language, duration_seconds, transcription, audio_path, status) VALUES (?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }

        let iso = Self.isoFormatter.string(from: Date())
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
        let rowID = sqlite3_last_insert_rowid(db)
        notifyDidChange()
        return rowID
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
        notifyDidChange()
    }

    /// Clean up audio files older than `days`
    func cleanupOldAudio(olderThanDays days: Int = 7) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let iso = Self.isoFormatter.string(from: cutoff)

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

        notifyDidChange()
    }

    // MARK: - History View Methods

    /// Fetch all transcription entries, newest first
    func fetchAll() -> [HistoryEntry] {
        return fetchEntries(limit: nil)
    }

    func fetchEntries(
        searchText: String = "",
        engineFilter: EngineFilter = .all,
        limit: Int? = 250,
        offset: Int = 0
    ) -> [HistoryEntry] {
        var sql = "SELECT id, timestamp, engine, language, duration_seconds, transcription, audio_path, status, is_favorite FROM transcriptions"
        var conditions: [String] = []
        var binders: [(OpaquePointer?, Int32) -> Void] = []

        if let enginePattern = enginePattern(for: engineFilter) {
            conditions.append("engine LIKE ? COLLATE NOCASE")
            binders.append { [enginePattern] stmt, index in
                self.bindText(stmt, index, enginePattern)
            }
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            let likePattern = "%\(escapeLike(trimmedSearch))%"
            conditions.append("transcription LIKE ? ESCAPE '\\' COLLATE NOCASE")
            binders.append { [likePattern] stmt, index in
                self.bindText(stmt, index, likePattern)
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        sql += " ORDER BY timestamp DESC"

        if let limit {
            sql += " LIMIT ? OFFSET ?"
            binders.append { stmt, index in
                sqlite3_bind_int64(stmt, index, Int64(limit))
            }
            binders.append { stmt, index in
                sqlite3_bind_int64(stmt, index, Int64(offset))
            }
        }

        sql += ";"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        for (index, binder) in binders.enumerated() {
            binder(stmt, Int32(index + 1))
        }

        var entries: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let timestampStr = String(cString: sqlite3_column_text(stmt, 1))
            let engine = String(cString: sqlite3_column_text(stmt, 2))
            let language = String(cString: sqlite3_column_text(stmt, 3))
            let duration = sqlite3_column_double(stmt, 4)
            let text = String(cString: sqlite3_column_text(stmt, 5))
            let audioPath: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let status = String(cString: sqlite3_column_text(stmt, 7))
            let isFavorite = sqlite3_column_int(stmt, 8) != 0

            let timestamp = Self.isoFormatter.date(from: timestampStr) ?? Date()

            entries.append(HistoryEntry(
                id: id, timestamp: timestamp, engine: engine, language: language,
                duration: duration, text: text, audioPath: audioPath,
                status: status, isFavorite: isFavorite
            ))
        }
        return entries
    }

    private func enginePattern(for filter: EngineFilter) -> String? {
        switch filter {
        case .all:
            return nil
        case .deepgram:
            return "%deepgram%"
        case .google:
            return "%google%"
        case .whisper:
            return "%whisper%"
        case .apple:
            return "%apple%"
        }
    }

    private func escapeLike(_ searchText: String) -> String {
        searchText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Toggle the favorite status of an entry. Returns new state.
    @discardableResult
    func toggleFavorite(id: Int64) -> Bool {
        let updateSql = "UPDATE transcriptions SET is_favorite = CASE WHEN is_favorite = 0 THEN 1 ELSE 0 END WHERE id = ?;"
        var updateStmt: OpaquePointer?
        defer { sqlite3_finalize(updateStmt) }
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(updateStmt, 1, id)
        sqlite3_step(updateStmt)

        // Read new state
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

    /// Delete a transcription entry and its audio file
    func delete(id: Int64) {
        // Get audio path first
        let selectSql = "SELECT audio_path FROM transcriptions WHERE id = ?;"
        var selectStmt: OpaquePointer?
        sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil)
        sqlite3_bind_int64(selectStmt, 1, id)
        var audioPath: String?
        if sqlite3_step(selectStmt) == SQLITE_ROW, sqlite3_column_type(selectStmt, 0) != SQLITE_NULL {
            audioPath = String(cString: sqlite3_column_text(selectStmt, 0))
        }
        sqlite3_finalize(selectStmt)

        // Delete DB entry
        let deleteSql = "DELETE FROM transcriptions WHERE id = ?;"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(deleteStmt, 1, id)
        sqlite3_step(deleteStmt)

        // Delete audio file
        if let path = audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }

        notifyDidChange()
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
