//
//  TranscriptionHistoryManager+Queries.swift
//  SapoWhisper
//

import Foundation
import SQLite3

nonisolated extension TranscriptionHistoryManager {
    /// Fetch all transcription entries, newest first.
    func fetchAll() -> [HistoryEntry] {
        fetchEntries(limit: nil)
    }

    /// Targeted single-row duration lookup for the retry path, so it does not
    /// materialize the whole table via `fetchAll()` just to read one value.
    func duration(for id: Int64) -> TimeInterval? {
        let sql = "SELECT duration_seconds FROM transcriptions WHERE id = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    func fetchEntries(
        searchText: String = "",
        engineFilter: EngineFilter = .all,
        limit: Int? = 250,
        offset: Int = 0
    ) -> [HistoryEntry] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // H2: searches go through the FTS5 index (linear LIKE scans get slow
        // past a few thousand rows). LIKE remains as the fallback when the
        // index is unavailable or the FTS query fails.
        if !trimmedSearch.isEmpty, schemaVersion() >= 3,
            let ftsQuery = Self.ftsPrefixQuery(from: trimmedSearch)
        {
            let entries = runFetch(
                searchCondition: (
                    sql: "id IN (SELECT rowid FROM transcriptions_fts WHERE transcriptions_fts MATCH ?)",
                    bindings: [ftsQuery]
                ),
                engineFilter: engineFilter, limit: limit, offset: offset
            )
            if let entries {
                return entries
            }
        }

        var searchCondition: (sql: String, bindings: [String])?
        if !trimmedSearch.isEmpty {
            let likePattern = "%\(escapeLike(trimmedSearch))%"
            searchCondition = (
                sql:
                    "(transcription LIKE ? ESCAPE '\\' COLLATE NOCASE OR raw_transcription LIKE ? ESCAPE '\\' COLLATE NOCASE)",
                bindings: [likePattern, likePattern]
            )
        }

        return runFetch(
            searchCondition: searchCondition,
            engineFilter: engineFilter, limit: limit, offset: offset
        ) ?? []
    }

    /// Builds the SELECT shared by the FTS and LIKE paths. Returns nil when
    /// the statement fails to prepare or step (so FTS errors can fall back).
    private func runFetch(
        searchCondition: (sql: String, bindings: [String])?,
        engineFilter: EngineFilter,
        limit: Int?,
        offset: Int
    ) -> [HistoryEntry]? {
        var sql =
            """
            SELECT id, timestamp, engine, language, duration_seconds, transcription, raw_transcription,
                   audio_path, status, is_favorite, ai_status, ai_model, ai_mode, ai_error,
                   failure_code, ai_first_status, ai_first_model, ai_first_mode
            FROM transcriptions
            """
        var conditions: [String] = []
        var binders: [(OpaquePointer?, Int32) -> Void] = []

        if let engineCondition = engineCondition(for: engineFilter) {
            conditions.append(engineCondition.sql)
            for pattern in engineCondition.patterns {
                binders.append { [pattern] stmt, index in
                    self.bindText(stmt, index, pattern)
                }
            }
        }

        if let searchCondition {
            conditions.append(searchCondition.sql)
            for binding in searchCondition.bindings {
                binders.append { [binding] stmt, index in
                    self.bindText(stmt, index, binding)
                }
            }
        }

        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }

        // Tie-break by id so rows sharing a timestamp (two dictations in the same
        // second) keep a stable order across separate LIMIT/OFFSET page queries —
        // otherwise incremental paging could duplicate or skip a row.
        sql += " ORDER BY timestamp DESC, id DESC"

        if let limit {
            sql += " LIMIT ? OFFSET ?"
            binders.append { stmt, index in sqlite3_bind_int64(stmt, index, Int64(limit)) }
            binders.append { stmt, index in sqlite3_bind_int64(stmt, index, Int64(offset)) }
        }

        sql += ";"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }

        for (index, binder) in binders.enumerated() {
            binder(stmt, Int32(index + 1))
        }

        var entries: [HistoryEntry] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                entries.append(makeEntry(from: stmt))
            } else if result == SQLITE_DONE {
                return entries
            } else {
                return nil
            }
        }
    }

    /// Turns free text into a safe FTS5 prefix query: each whitespace-separated
    /// term becomes a quoted prefix token ("term"*), joined with implicit AND.
    static func ftsPrefixQuery(from searchText: String) -> String? {
        let terms =
            searchText
            .split(whereSeparator: { $0.isWhitespace })
            .map { term -> String in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
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
        let failureCode: String? =
            sqlite3_column_type(stmt, 14) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 14)) : nil
        let aiFirstStatus: String? =
            sqlite3_column_type(stmt, 15) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 15)) : nil
        let aiFirstModel: String? =
            sqlite3_column_type(stmt, 16) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 16)) : nil
        let aiFirstMode: String? =
            sqlite3_column_type(stmt, 17) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(stmt, 17)) : nil
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
            isFavorite: isFavorite,
            failureCode: failureCode,
            aiFirstStatus: aiFirstStatus,
            aiFirstModel: aiFirstModel,
            aiFirstMode: aiFirstMode
        )
    }

    private func engineCondition(for filter: EngineFilter) -> (sql: String, patterns: [String])? {
        switch filter {
        case .all:
            return nil
        case .whisper:
            return ("engine LIKE ? COLLATE NOCASE", ["%whisper%"])
        case .deepgram:
            return ("engine LIKE ? COLLATE NOCASE", ["%deepgram%"])
        case .elevenLabs:
            return ("engine LIKE ? COLLATE NOCASE", ["%elevenlabs%"])
        case .other:
            return (
                "engine NOT LIKE ? COLLATE NOCASE AND engine NOT LIKE ? COLLATE NOCASE AND engine NOT LIKE ? COLLATE NOCASE",
                ["%whisper%", "%deepgram%", "%elevenlabs%"]
            )
        }
    }

    private func escapeLike(_ searchText: String) -> String {
        searchText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
