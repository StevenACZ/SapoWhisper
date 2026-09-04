//
//  HistoryRetentionSweepGuardTests.swift
//  SapoWhisperTests
//
//  The two paths that delete History audio may only remove what they can prove
//  is expendable: the age-based retention delete must spare a row whose engine
//  is still running (its WAV is the only copy of that dictation), and the
//  orphan sweep must abort when the reference scan cannot finish, because a
//  truncated set of referenced paths is indistinguishable from a complete one.
//

import SQLite3
import XCTest

@testable import SapoWhisper

@MainActor
final class HistoryRetentionSweepGuardTests: XCTestCase {

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-retention-sweep-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
    }

    override func tearDown() async throws {
        allowQueries()
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        try await super.tearDown()
    }

    // MARK: - Retention delete

    func testRetentionDeleteKeepsInFlightRowAndItsAudio() throws {
        let inFlight = persistRow(named: "in-flight", status: "transcribing")
        let resolved = persistRow(named: "resolved", status: "completed")
        backdate(ids: [inFlight.rowID, resolved.rowID], days: 60)

        let deleted = manager.deleteEntries(olderThanDays: 30)

        XCTAssertEqual(deleted, 1, "only the resolved row may age out")
        XCTAssertEqual(manager.fetchAll().map(\.id), [inFlight.rowID])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(inFlight.audioPath)),
            "the retention sweep destroyed the only copy of the in-flight dictation audio"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(resolved.audioPath)))
    }

    func testRetentionKeepsPolishingRowsAndTheirAudio() throws {
        let pending = persistRow(named: "polishing", status: "polishing")
        backdate(ids: [pending.rowID], days: 60)
        XCTAssertEqual(manager.deleteEntries(olderThanDays: 30), 0)
        XCTAssertEqual(manager.fetchAll().map(\.id), [pending.rowID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(pending.audioPath)))
    }

    /// The guard is scoped to the in-flight status: once the pipeline resolves
    /// the row, retention removes it normally.
    func testRetentionDeleteRemovesTheRowOnceItResolves() throws {
        let row = persistRow(named: "resolving", status: "transcribing")
        backdate(ids: [row.rowID], days: 60)
        manager.markTranscriptionFailed(id: row.rowID, failureCode: "test/failed")

        XCTAssertEqual(manager.deleteEntries(olderThanDays: 30), 1)
        XCTAssertTrue(manager.fetchAll().isEmpty)
    }

    // MARK: - Orphan sweep

    func testOrphanSweepKeepsAudioWhenTheReferenceScanCannotFinish() throws {
        let row = persistRow(named: "keeper", status: "completed")
        let audioPath = try XCTUnwrap(row.audioPath)

        interruptEveryQuery()
        manager.enforceAudioStorageLimit()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioPath),
            "an incomplete reference scan let the sweep delete referenced audio"
        )
    }

    /// The guard skips the sweep, it does not disable it: a genuine orphan is
    /// still collected once the database answers again.
    func testOrphanSweepResumesOnceTheDatabaseAnswersAgain() throws {
        let row = persistRow(named: "keeper", status: "completed")
        let orphan = audioDirectory.appendingPathComponent("audio_\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: orphan.path, contents: Data(repeating: 0, count: 2048))

        interruptEveryQuery()
        manager.enforceAudioStorageLimit()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: orphan.path),
            "the sweep ran on a reference scan that never completed"
        )

        allowQueries()
        manager.enforceAudioStorageLimit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "the sweep must resume collecting orphans once the scan completes"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(row.audioPath)))
    }

    // MARK: - Helpers

    private var audioDirectory: URL {
        tempAudioDir.appendingPathComponent("audio", isDirectory: true)
    }

    /// Makes every statement on the connection stop at SQLITE_INTERRUPT, the
    /// way a mid-scan corruption, I/O error, or busy connection would.
    private func interruptEveryQuery() {
        sqlite3_progress_handler(manager.db, 1, { _ in 1 }, nil)
    }

    private func allowQueries() {
        guard let db = manager?.db else { return }
        sqlite3_progress_handler(db, 0, nil, nil)
    }

    private func backdate(ids: [Int64], days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let iso = TranscriptionHistoryManager.isoFormatter.string(from: cutoff)
        for id in ids {
            let sql = "UPDATE transcriptions SET timestamp = '\(iso)' WHERE id = \(id);"
            XCTAssertEqual(sqlite3_exec(manager.db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func persistRow(named name: String, status: String) -> (rowID: Int64, audioPath: String?) {
        let source = tempAudioDir.appendingPathComponent("source-\(name)-\(UUID().uuidString).wav")
        try? FileManager.default.createDirectory(at: tempAudioDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 0, count: 2048))

        let result = manager.persistEntry(
            audioSource: source,
            engine: "Deepgram Nova-3",
            language: "es",
            duration: 3,
            text: name,
            status: status
        )
        return (result.rowID, result.audioPath)
    }
}
