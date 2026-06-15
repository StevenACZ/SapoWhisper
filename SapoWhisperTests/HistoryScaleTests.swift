//
//  HistoryScaleTests.swift
//  SapoWhisperTests
//

import SQLite3
import XCTest

@testable import SapoWhisper

final class HistoryScaleTests: XCTestCase {

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!

    override func setUp() {
        super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
    }

    override func tearDown() {
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        super.tearDown()
    }

    // MARK: - H8: schema versioning

    func testFreshDatabaseMigratesToCurrentSchemaVersion() {
        XCTAssertEqual(manager.schemaVersion(), 3)
    }

    // MARK: - H7: failure code

    func testFailureCodeRoundTrips() {
        manager.save(
            engine: "ElevenLabs", language: "es", duration: 3, text: "",
            status: "failed", failureCode: "ElevenLabs/auth"
        )

        let entries = manager.fetchEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.failureCode, "ElevenLabs/auth")
    }

    // MARK: - H2: FTS search

    func testSearchFindsSavedTextByPrefix() {
        manager.save(engine: "Deepgram", language: "es", duration: 2, text: "reunión con marketing mañana")
        manager.save(engine: "Deepgram", language: "es", duration: 2, text: "lista de la compra")

        let hits = manager.fetchEntries(searchText: "reuni")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits.first?.text.contains("marketing") ?? false)
    }

    func testSearchIgnoresDiacritics() {
        manager.save(engine: "Deepgram", language: "es", duration: 2, text: "canción favorita")

        XCTAssertEqual(manager.fetchEntries(searchText: "cancion").count, 1)
    }

    func testSearchMatchesRawTranscriptionToo() {
        manager.save(
            engine: "Deepgram", language: "es", duration: 2,
            text: "texto pulido", rawText: "texto crudo distintivo"
        )

        XCTAssertEqual(manager.fetchEntries(searchText: "distintivo").count, 1)
    }

    func testSearchUpdatesAfterRetranscription() {
        let id = manager.save(engine: "Deepgram", language: "es", duration: 2, text: "antes original")
        manager.updateRetranscription(
            id: id, engine: "WhisperKit", finalText: "después renovado", rawText: "después renovado",
            aiStatus: .none, aiModel: nil, aiMode: nil, aiError: nil
        )

        XCTAssertEqual(manager.fetchEntries(searchText: "renovado").count, 1)
        XCTAssertTrue(manager.fetchEntries(searchText: "original").isEmpty)
    }

    // MARK: - Incremental paging

    func testIncrementalPagingReturnsEachRowExactlyOnce() {
        var savedIds: [Int64] = []
        for index in 0..<25 {
            savedIds.append(
                manager.save(engine: "Deepgram", language: "es", duration: 1, text: "fila \(index)")
            )
        }

        var pagedIds: [Int64] = []
        let pageSize = 10
        var offset = 0
        while true {
            let page = manager.fetchEntries(limit: pageSize, offset: offset)
            if page.isEmpty { break }
            pagedIds.append(contentsOf: page.map { $0.id })
            offset += page.count
            if page.count < pageSize { break }
        }

        // Every saved row appears exactly once across pages — no duplicate, no skip.
        XCTAssertEqual(pagedIds.count, savedIds.count)
        XCTAssertEqual(Set(pagedIds), Set(savedIds))
    }

    func testPagingOrderIsStableNewestFirst() {
        let first = manager.save(engine: "Deepgram", language: "es", duration: 1, text: "a")
        let second = manager.save(engine: "Deepgram", language: "es", duration: 1, text: "b")
        let third = manager.save(engine: "Deepgram", language: "es", duration: 1, text: "c")

        // Newest first; rows sharing a timestamp fall back to id DESC, so the
        // order stays stable across paged queries.
        XCTAssertEqual(manager.fetchEntries(limit: nil).map { $0.id }, [third, second, first])
    }

    func testSearchAtFiveThousandRows() {
        for index in 0..<5000 {
            manager.save(
                engine: "Deepgram", language: "es", duration: 1,
                text: "entrada número \(index) de relleno"
            )
        }
        manager.save(engine: "Deepgram", language: "es", duration: 1, text: "aguja zanahoria única")

        let hits = manager.fetchEntries(searchText: "zanahoria")
        XCTAssertEqual(hits.count, 1)

        let paged = manager.fetchEntries(limit: 200, offset: 0)
        XCTAssertEqual(paged.count, 200)
    }

    func testFtsPrefixQueryQuotesAndEscapesTerms() {
        XCTAssertEqual(
            TranscriptionHistoryManager.ftsPrefixQuery(from: "hola mundo"),
            "\"hola\"* \"mundo\"*"
        )
        XCTAssertEqual(
            TranscriptionHistoryManager.ftsPrefixQuery(from: "con\"comilla"),
            "\"con\"\"comilla\"*"
        )
        XCTAssertNil(TranscriptionHistoryManager.ftsPrefixQuery(from: "   "))
    }

    // MARK: - H10: first polish preserved

    func testRePolishPreservesFirstPolishMetadata() {
        let id = manager.save(engine: "Deepgram", language: "es", duration: 2, text: "raw")
        manager.updateAIProcessing(
            id: id, finalText: "primera pulida", rawText: "raw",
            aiStatus: .applied, aiModel: "openrouter/gpt-5.4-nano", aiMode: "automatic", aiError: nil
        )
        manager.updateAIProcessing(
            id: id, finalText: "segunda pulida", rawText: "raw",
            aiStatus: .applied, aiModel: "openrouter/gpt-5.4-mini", aiMode: "work_message", aiError: nil
        )

        let entry = manager.fetchEntries().first
        XCTAssertEqual(entry?.aiModel, "openrouter/gpt-5.4-mini")
        XCTAssertEqual(entry?.aiFirstStatus, "applied")
        XCTAssertEqual(entry?.aiFirstModel, "openrouter/gpt-5.4-nano")
        XCTAssertEqual(entry?.aiFirstMode, "automatic")
    }

    func testFirstPolishNotOverwrittenByThirdPolish() {
        let id = manager.save(engine: "Deepgram", language: "es", duration: 2, text: "raw")
        for model in ["model-a", "model-b", "model-c"] {
            manager.updateAIProcessing(
                id: id, finalText: "pulida \(model)", rawText: "raw",
                aiStatus: .applied, aiModel: model, aiMode: "automatic", aiError: nil
            )
        }

        let entry = manager.fetchEntries().first
        XCTAssertEqual(entry?.aiModel, "model-c")
        XCTAssertEqual(entry?.aiFirstModel, "model-a")
    }

    // MARK: - H5: batch delete

    func testDeleteAllRemovesEverything() {
        for index in 0..<5 {
            manager.save(engine: "Deepgram", language: "es", duration: 1, text: "fila \(index)")
        }

        let deleted = manager.deleteAll()

        XCTAssertEqual(deleted, 5)
        XCTAssertTrue(manager.fetchEntries().isEmpty)
    }

    func testDeleteOlderThanKeepsRecentAndPinned() {
        let oldID = manager.save(engine: "Deepgram", language: "es", duration: 1, text: "vieja")
        let pinnedOldID = manager.save(engine: "Deepgram", language: "es", duration: 1, text: "vieja fijada")
        manager.toggleFavorite(id: pinnedOldID)
        backdate(ids: [oldID, pinnedOldID], days: 60)
        manager.save(engine: "Deepgram", language: "es", duration: 1, text: "reciente")

        let deleted = manager.deleteEntries(olderThanDays: 30)

        XCTAssertEqual(deleted, 1)
        let remaining = manager.fetchEntries().map(\.text).sorted()
        XCTAssertEqual(remaining, ["reciente", "vieja fijada"])
    }

    /// Rewrites timestamps directly so retention tests can age rows.
    private func backdate(ids: [Int64], days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let iso = TranscriptionHistoryManager.isoFormatter.string(from: cutoff)
        for id in ids {
            let sql = "UPDATE transcriptions SET timestamp = '\(iso)' WHERE id = \(id);"
            XCTAssertEqual(sqlite3_exec(manager.db, sql, nil, nil, nil), SQLITE_OK)
        }
    }
}

// MARK: - Exporter

final class HistoryExporterTests: XCTestCase {

    private let entry = HistoryEntry(
        id: 7, timestamp: Date(timeIntervalSince1970: 1_750_000_000), engine: "Deepgram Nova-3",
        language: "es", duration: 12.5, text: "texto, con \"comillas\"", rawText: "texto crudo",
        audioPath: nil, status: "completed", aiStatus: "applied",
        aiModel: "gpt-5.4-nano", aiMode: "automatic", aiError: nil, isFavorite: true,
        failureCode: nil, aiFirstStatus: nil, aiFirstModel: nil, aiFirstMode: nil
    )

    func testCSVEscapesCommasAndQuotes() {
        XCTAssertEqual(HistoryExporter.csvEscaped("plain"), "plain")
        XCTAssertEqual(HistoryExporter.csvEscaped("a,b"), "\"a,b\"")
        XCTAssertEqual(HistoryExporter.csvEscaped("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(HistoryExporter.csvEscaped("line\nbreak"), "\"line\nbreak\"")
    }

    func testCSVHasHeaderAndOneRowPerEntry() {
        let csv = HistoryExporter.render([entry], as: .csv)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines[0].hasPrefix("timestamp,engine,language"))
        XCTAssertTrue(csv.contains("\"texto, con \"\"comillas\"\"\""))
    }

    func testJSONContainsExpectedFields() throws {
        let json = HistoryExporter.render([entry], as: .json)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["engine"] as? String, "Deepgram Nova-3")
        XCTAssertEqual(decoded[0]["favorite"] as? Bool, true)
        XCTAssertEqual(decoded[0]["durationSeconds"] as? Double, 12.5)
    }

    func testTXTContainsHeaderAndText() {
        let txt = HistoryExporter.render([entry], as: .txt)
        XCTAssertTrue(txt.contains("Deepgram Nova-3"))
        XCTAssertTrue(txt.contains("texto, con \"comillas\""))
    }

    func testSuggestedFileNameUsesFormatExtension() {
        let name = HistoryExporter.suggestedFileName(
            for: .csv, date: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertTrue(name.hasPrefix("sapowhisper-history-"))
        XCTAssertTrue(name.hasSuffix(".csv"))
    }
}
