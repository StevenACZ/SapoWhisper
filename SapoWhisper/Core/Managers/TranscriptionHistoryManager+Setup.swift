//
//  TranscriptionHistoryManager+Setup.swift
//  SapoWhisper
//

import Foundation
import SQLite3

extension TranscriptionHistoryManager {
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
            audio_path TEXT,
            status TEXT NOT NULL DEFAULT 'completed',
            is_favorite INTEGER NOT NULL DEFAULT 0
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func migrateSchema() {
        guard !columnExists(named: "is_favorite", in: "transcriptions") else { return }

        let sql = "ALTER TABLE transcriptions ADD COLUMN is_favorite INTEGER DEFAULT 0;"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK,
           let message = sqlite3_errmsg(db) {
            print("Failed to migrate history schema: \(String(cString: message))")
        }
    }

    func createIndexes() {
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
}
