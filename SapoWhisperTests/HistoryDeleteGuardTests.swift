//
//  HistoryDeleteGuardTests.swift
//  SapoWhisperTests
//
//  A pre-persisted "transcribing" row owns the only copy of the audio
//  the engine is still consuming, so every History delete path must refuse it
//  until the pipeline (or the launch sweep) resolves the row.
//

import XCTest

@testable import SapoWhisper

@MainActor
final class HistoryDeleteGuardTests: XCTestCase {

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-delete-guard-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
    }

    override func tearDown() async throws {
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        try await super.tearDown()
    }

    func testDeleteAllKeepsInFlightRowAndItsAudio() throws {
        let completed = persistRow(named: "completed", status: "completed")
        let inFlight = persistRow(named: "in-flight", status: "transcribing")

        let deleted = manager.deleteAll()

        XCTAssertEqual(deleted, 1, "deleteAll must remove only the resolved rows")
        let remaining = manager.fetchAll()
        XCTAssertEqual(remaining.map(\.id), [inFlight.rowID])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(inFlight.audioPath)),
            "deleteAll destroyed the only copy of the in-flight dictation audio"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.audioPath)))
    }

    func testDeleteRefusesInFlightRowAndKeepsItsAudio() throws {
        let inFlight = persistRow(named: "in-flight", status: "transcribing")

        manager.delete(id: inFlight.rowID)

        XCTAssertEqual(manager.fetchAll().map(\.id), [inFlight.rowID])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: try XCTUnwrap(inFlight.audioPath)),
            "delete(id:) destroyed the only copy of the in-flight dictation audio"
        )
    }

    /// The guard is scoped to the in-flight status: a resolved row still deletes.
    func testDeleteRemovesResolvedRowAndItsAudio() throws {
        let completed = persistRow(named: "completed", status: "completed")

        manager.delete(id: completed.rowID)

        XCTAssertTrue(manager.fetchAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(completed.audioPath)))
    }

    /// A row the pipeline resolved after the sweep began deletes normally, so
    /// the guard cannot strand rows in History forever.
    func testResolvedInFlightRowBecomesDeletable() {
        let inFlight = persistRow(named: "in-flight", status: "transcribing")
        manager.markTranscriptionFailed(id: inFlight.rowID, failureCode: "test/failed")

        manager.delete(id: inFlight.rowID)

        XCTAssertTrue(manager.fetchAll().isEmpty)
    }

    func testIsDeletableMirrorsTheSQLGuard() {
        let inFlight = persistRow(named: "in-flight", status: "transcribing")
        let completed = persistRow(named: "completed", status: "completed")
        let entries = manager.fetchAll()

        XCTAssertEqual(entries.first { $0.id == inFlight.rowID }?.isDeletable, false)
        XCTAssertEqual(entries.first { $0.id == completed.rowID }?.isDeletable, true)
    }

    func testLatePolishCannotRecreateDeletedHistoryText() {
        let id = manager.save(engine: "test", language: "en", duration: 2, text: "original")
        manager.delete(id: id)

        manager.updateAIProcessing(
            id: id, finalText: "late result", rawText: "original", aiStatus: .applied,
            aiModel: "test", aiMode: "normal", aiError: nil
        )

        XCTAssertTrue(manager.fetchAll().isEmpty)
        XCTAssertTrue(manager.polishVersions(for: id).isEmpty)
    }

    func testLateRetranscriptionCannotRecreateClearedHistoryText() {
        let id = manager.save(engine: "test", language: "en", duration: 2, text: "original")
        manager.deleteAll()

        manager.updateRetranscription(
            id: id, engine: "test", finalText: "late result", rawText: "original",
            aiStatus: .applied, aiModel: "test", aiMode: "normal", aiError: nil
        )

        XCTAssertTrue(manager.fetchAll().isEmpty)
        XCTAssertTrue(manager.polishVersions(for: id).isEmpty)
    }

    func testPolishingRowCannotBeDeletedAndRecoversRecognizedText() throws {
        let entry = persistRow(named: "", status: "transcribing")
        manager.markProcessingStage(id: entry.rowID, stage: .polishing, rawText: "Recognized before interruption")
        XCTAssertEqual(manager.fetchAll().first?.entryStatus, .polishing)
        XCTAssertFalse(try XCTUnwrap(manager.fetchAll().first).isDeletable)
        manager.delete(id: entry.rowID)
        XCTAssertEqual(manager.deleteAll(), 0)
        XCTAssertEqual(manager.fetchAll().map(\.id), [entry.rowID])
        _ = manager.recoverInterruptedTranscriptions()
        let recovered = try XCTUnwrap(manager.fetchAll().first)
        XCTAssertEqual(recovered.entryStatus, .failed)
        XCTAssertEqual(recovered.rawText, "Recognized before interruption")
        XCTAssertEqual(recovered.text, "Recognized before interruption")
        XCTAssertEqual(recovered.failureKind, .recordingInterrupted)
        XCTAssertTrue(recovered.isDeletable)
        XCTAssertTrue(recovered.audioFileExists)
    }

    func testAStaleProcessingUpdateCannotReviveACancelledRow() throws {
        let entry = persistRow(named: "", status: "transcribing")
        manager.markTranscriptionFailed(id: entry.rowID, failureCode: "test/user_cancelled")
        manager.markProcessingStage(id: entry.rowID, stage: .polishing, rawText: "late text")
        let cancelled = try XCTUnwrap(manager.fetchAll().first)
        XCTAssertTrue(cancelled.isUserCancelled)
        XCTAssertEqual(cancelled.rawText, "")
    }

    // MARK: - Helpers

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
