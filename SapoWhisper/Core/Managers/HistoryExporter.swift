//
//  HistoryExporter.swift
//  SapoWhisper
//

import Foundation

nonisolated enum HistoryExportFormat: String, CaseIterable, Identifiable {
    case txt
    case json
    case csv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: return "TXT"
        case .json: return "JSON"
        case .csv: return "CSV"
        }
    }

    var fileExtension: String { rawValue }
}

/// H4: renders history entries into shareable text formats. Pure functions so
/// the formats are unit-testable; file writing stays in the UI layer.
nonisolated enum HistoryExporter {

    static func render(_ entries: [HistoryEntry], as format: HistoryExportFormat) -> String {
        switch format {
        case .txt: return renderTXT(entries)
        case .json: return renderJSON(entries)
        case .csv: return renderCSV(entries)
        }
    }

    static func suggestedFileName(for format: HistoryExportFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "sapowhisper-history-\(formatter.string(from: date)).\(format.fileExtension)"
    }

    // MARK: - Formats

    private static func renderTXT(_ entries: [HistoryEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        let blocks = entries.map { entry in
            let header = "[\(formatter.string(from: entry.timestamp))] \(entry.engine) · \(entry.language) · \(entry.formattedDuration)"
            return "\(header)\n\(entry.text)"
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func renderJSON(_ entries: [HistoryEntry]) -> String {
        let payload = entries.map(ExportedEntry.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func renderCSV(_ entries: [HistoryEntry]) -> String {
        let header = "timestamp,engine,language,duration_seconds,status,ai_status,ai_model,ai_mode,failure_code,favorite,text,raw_text"
        let formatter = ISO8601DateFormatter()
        let rows = entries.map { entry in
            [
                formatter.string(from: entry.timestamp),
                entry.engine,
                entry.language,
                String(format: "%.1f", entry.duration),
                entry.status,
                entry.aiStatus,
                entry.aiModel ?? "",
                entry.aiMode ?? "",
                entry.failureCode ?? "",
                entry.isFavorite ? "1" : "0",
                entry.text,
                entry.rawText,
            ]
            .map(csvEscaped)
            .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    /// Quotes any field containing a comma, quote, or newline (RFC 4180).
    static func csvEscaped(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private struct ExportedEntry: Encodable {
        let id: Int64
        let timestamp: Date
        let engine: String
        let language: String
        let durationSeconds: TimeInterval
        let text: String
        let rawText: String
        let status: String
        let aiStatus: String
        let aiModel: String?
        let aiMode: String?
        let failureCode: String?
        let favorite: Bool

        init(_ entry: HistoryEntry) {
            id = entry.id
            timestamp = entry.timestamp
            engine = entry.engine
            language = entry.language
            durationSeconds = entry.duration
            text = entry.text
            rawText = entry.rawText
            status = entry.status
            aiStatus = entry.aiStatus
            aiModel = entry.aiModel
            aiMode = entry.aiMode
            failureCode = entry.failureCode
            favorite = entry.isFavorite
        }
    }
}
