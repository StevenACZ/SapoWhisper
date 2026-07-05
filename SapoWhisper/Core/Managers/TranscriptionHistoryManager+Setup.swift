//
//  TranscriptionHistoryManager+Setup.swift
//  SapoWhisper
//

import Foundation
import SQLite3
import os

nonisolated extension TranscriptionHistoryManager {
    func configureDatabase() {
        sqlite3_busy_timeout(db, 1000)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA temp_store = MEMORY;", nil, nil, nil)
    }

    func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS transcriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                engine TEXT NOT NULL,
                language TEXT NOT NULL,
                duration_seconds REAL NOT NULL,
                transcription TEXT NOT NULL,
                raw_transcription TEXT,
                audio_path TEXT,
                status TEXT NOT NULL DEFAULT 'completed',
                ai_status TEXT NOT NULL DEFAULT 'none',
                ai_model TEXT,
                ai_mode TEXT,
                ai_error TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0
            );
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// H8: versioned migrations via `PRAGMA user_version` instead of probing
    /// columns forever. Version 1 captures the legacy add-column state; later
    /// versions run exactly once.
    func migrateSchema() {
        var version = schemaVersion()

        if version < 1 {
            addColumnIfNeeded(named: "is_favorite", definition: "INTEGER DEFAULT 0")
            addColumnIfNeeded(named: "raw_transcription", definition: "TEXT")
            addColumnIfNeeded(named: "ai_status", definition: "TEXT NOT NULL DEFAULT 'none'")
            addColumnIfNeeded(named: "ai_model", definition: "TEXT")
            addColumnIfNeeded(named: "ai_mode", definition: "TEXT")
            addColumnIfNeeded(named: "ai_error", definition: "TEXT")
            addColumnIfNeeded(named: "original_engine", definition: "TEXT")
            backfillRawTranscriptions()
            version = setSchemaVersion(1) ? 1 : version
        }

        if version == 1 {
            // H7: semantic failure kind for failed rows; H10: first-polish
            // audit metadata preserved across re-polishes.
            addColumnIfNeeded(named: "failure_code", definition: "TEXT")
            addColumnIfNeeded(named: "ai_first_status", definition: "TEXT")
            addColumnIfNeeded(named: "ai_first_model", definition: "TEXT")
            addColumnIfNeeded(named: "ai_first_mode", definition: "TEXT")
            version = setSchemaVersion(2) ? 2 : version
        }

        if version == 2 {
            if createSearchIndex(backfill: true) {
                version = setSchemaVersion(3) ? 3 : version
            }
        }

        if version == 3 {
            if createPolishVersionsTable(backfill: true) {
                version = setSchemaVersion(4) ? 4 : version
            }
        }
    }

    func schemaVersion() -> Int32 {
        let sql = "PRAGMA user_version;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW
        else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    private func setSchemaVersion(_ version: Int32) -> Bool {
        sqlite3_exec(db, "PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK
    }

    /// H2: external-content FTS5 index over both transcript columns, kept in
    /// sync by triggers. LIKE scans go linear past a few thousand rows.
    private func createSearchIndex(backfill: Bool) -> Bool {
        let createSQL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS transcriptions_fts USING fts5(
                transcription, raw_transcription,
                content='transcriptions', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS transcriptions_fts_insert
            AFTER INSERT ON transcriptions BEGIN
                INSERT INTO transcriptions_fts(rowid, transcription, raw_transcription)
                VALUES (new.id, new.transcription, COALESCE(new.raw_transcription, ''));
            END;
            CREATE TRIGGER IF NOT EXISTS transcriptions_fts_delete
            AFTER DELETE ON transcriptions BEGIN
                INSERT INTO transcriptions_fts(transcriptions_fts, rowid, transcription, raw_transcription)
                VALUES ('delete', old.id, old.transcription, COALESCE(old.raw_transcription, ''));
            END;
            CREATE TRIGGER IF NOT EXISTS transcriptions_fts_update
            AFTER UPDATE OF transcription, raw_transcription ON transcriptions BEGIN
                INSERT INTO transcriptions_fts(transcriptions_fts, rowid, transcription, raw_transcription)
                VALUES ('delete', old.id, old.transcription, COALESCE(old.raw_transcription, ''));
                INSERT INTO transcriptions_fts(rowid, transcription, raw_transcription)
                VALUES (new.id, new.transcription, COALESCE(new.raw_transcription, ''));
            END;
            """

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            SapoLog.recording.error(
                "failure=History/createSearchIndex detail=\(message, privacy: .public)"
            )
            return false
        }

        guard backfill else { return true }
        let backfillSQL = """
            INSERT INTO transcriptions_fts(rowid, transcription, raw_transcription)
            SELECT id, transcription, COALESCE(raw_transcription, '') FROM transcriptions;
            """
        if sqlite3_exec(db, backfillSQL, nil, nil, nil) != SQLITE_OK {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            SapoLog.recording.error(
                "failure=History/backfillSearchIndex detail=\(message, privacy: .public)"
            )
            return false
        }
        return true
    }

    /// Every applied polish of an entry, oldest first. The row's ai_* columns
    /// keep only the latest polish; this table preserves the full regeneration
    /// trail so re-polishing never destroys a previous result.
    private func createPolishVersionsTable(backfill: Bool) -> Bool {
        let createSQL = """
            CREATE TABLE IF NOT EXISTS polish_versions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                model TEXT,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_polish_versions_entry ON polish_versions(entry_id, created_at);
            """
        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            SapoLog.recording.error(
                "failure=History/createPolishVersions detail=\(message, privacy: .public)"
            )
            return false
        }

        guard backfill else { return true }
        // Existing rows only know their latest applied polish; seed it as the
        // first version so old entries show a trail too.
        let backfillSQL = """
            INSERT INTO polish_versions(entry_id, created_at, model, text)
            SELECT id, timestamp, ai_model, transcription FROM transcriptions
            WHERE ai_status = 'applied' AND transcription != '';
            """
        if sqlite3_exec(db, backfillSQL, nil, nil, nil) != SQLITE_OK {
            let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
            SapoLog.recording.error(
                "failure=History/backfillPolishVersions detail=\(message, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func addColumnIfNeeded(named columnName: String, definition: String) {
        guard !columnExists(named: columnName, in: "transcriptions") else { return }

        let sql = "ALTER TABLE transcriptions ADD COLUMN \(columnName) \(definition);"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK,
            let message = sqlite3_errmsg(db)
        {
            let messageString = String(cString: message)
            SapoLog.recording.error(
                "History migrate failed column=\(columnName, privacy: .public) error=\(messageString, privacy: .public)"
            )
        }
    }

    private func backfillRawTranscriptions() {
        let sql = """
            UPDATE transcriptions
            SET raw_transcription = transcription
            WHERE raw_transcription IS NULL OR raw_transcription = '';
            """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func createIndexes() {
        let statements = [
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_timestamp ON transcriptions(timestamp DESC);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_status ON transcriptions(status);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_favorite_timestamp ON transcriptions(is_favorite, timestamp DESC);",
            "CREATE INDEX IF NOT EXISTS idx_transcriptions_engine_timestamp ON transcriptions(engine, timestamp DESC);",
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
}
