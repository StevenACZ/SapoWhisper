//
//  TranscriptionHistoryManager+Queries.swift
//  SapoWhisper
//

import Foundation
import SQLite3

extension TranscriptionHistoryManager {
    /// Fetch all transcription entries, newest first.
    func fetchAll() -> [HistoryEntry] {
        fetchEntries(limit: nil)
    }

    func fetchEntries(
        searchText: String = "",
        engineFilter: EngineFilter = .all,
        limit: Int? = 250,
        offset: Int = 0
    ) -> [HistoryEntry] {
        var sql =
            """
            SELECT id, timestamp, engine, language, duration_seconds, transcription, raw_transcription,
                   audio_path, status, is_favorite, ai_status, ai_model, ai_mode, ai_error
            FROM transcriptions
            """
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
            conditions.append(
                "(transcription LIKE ? ESCAPE '\\' COLLATE NOCASE OR raw_transcription LIKE ? ESCAPE '\\' COLLATE NOCASE)"
            )
            binders.append { [likePattern] stmt, index in
                self.bindText(stmt, index, likePattern)
            }
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
            binders.append { stmt, index in sqlite3_bind_int64(stmt, index, Int64(limit)) }
            binders.append { stmt, index in sqlite3_bind_int64(stmt, index, Int64(offset)) }
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
            entries.append(makeEntry(from: stmt))
        }
        return entries
    }

    func referencedAudioPaths() -> Set<String> {
        let sql = "SELECT audio_path FROM transcriptions WHERE audio_path IS NOT NULL;"
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

    private func makeEntry(from stmt: OpaquePointer?) -> HistoryEntry {
        let id = sqlite3_column_int64(stmt, 0)
        let timestampStr = String(cString: sqlite3_column_text(stmt, 1))
        let engine = String(cString: sqlite3_column_text(stmt, 2))
        let language = String(cString: sqlite3_column_text(stmt, 3))
        let duration = sqlite3_column_double(stmt, 4)
        let text = String(cString: sqlite3_column_text(stmt, 5))
        let rawText: String =
            sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 6)) : text
        let audioPath: String? =
            sqlite3_column_type(stmt, 7) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 7)) : nil
        let status = String(cString: sqlite3_column_text(stmt, 8))
        let isFavorite = sqlite3_column_int(stmt, 9) != 0
        let aiStatus: String =
            sqlite3_column_type(stmt, 10) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 10)) : TranscriptAIStatus.none.rawValue
        let aiModel: String? =
            sqlite3_column_type(stmt, 11) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 11)) : nil
        let aiMode: String? =
            sqlite3_column_type(stmt, 12) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 12)) : nil
        let aiError: String? =
            sqlite3_column_type(stmt, 13) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 13)) : nil
        let timestamp = Self.isoFormatter.date(from: timestampStr) ?? Date()

        return HistoryEntry(
            id: id,
            timestamp: timestamp,
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
            isFavorite: isFavorite
        )
    }

    private func enginePattern(for filter: EngineFilter) -> String? {
        switch filter {
        case .all:
            return nil
        case .deepgram:
            return "%deepgram%"
        case .gemini:
            return "%gemini%"
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
}
