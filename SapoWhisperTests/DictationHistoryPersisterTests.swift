//
//  DictationHistoryPersisterTests.swift
//  SapoWhisperTests
//
//  Persistence state machine for live dictations: aborted captures become
//  cancelled/failed rows pointing at the HISTORY audio copy, retries update
//  rows in place, failed retries keep the original row, and stale cleanup
//  never deletes the retry audio.
//

import SQLite3
import XCTest

@testable import SapoWhisper

@MainActor
final class DictationHistoryPersisterTests: XCTestCase {

    /// Records the URLs the persister asked to delete (the real closure wires
    /// to `AudioCaptureEngine.deleteRecording`); files stay on disk.
    private nonisolated final class DeleteSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
        }

        var deleted: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return urls
        }
    }

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!
    private var deleteSpy: DeleteSpy!
    private var persister: DictationHistoryPersister!

    override func setUp() {
        super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-persister-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
        deleteSpy = DeleteSpy()
        let spy = deleteSpy!
        persister = DictationHistoryPersister(historyManager: manager) { spy.record($0) }
    }

    override func tearDown() {
        persister = nil
        deleteSpy = nil
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        super.tearDown()
    }

    // MARK: - Aborted captures

    func testAbortPersistsCancelledRowAndKeepsAudio() throws {
        let source = makeSourceWAV(named: "abort")

        let outcome = persister.persistAbortedCapture(
            audioURL: source,
            duration: 2.4,
            engine: .deepgram,
            engineName: "Deepgram Nova-3",
            language: "es",
            failureKind: .userCancelled,
            storeRetryState: false
        )

        let entries = manager.fetchAll()
        XCTAssertEqual(entries.count, 1)
        let row = try XCTUnwrap(entries.first)
        XCTAssertEqual(row.status, "failed")
        XCTAssertEqual(
            row.failureCode,
            TranscriptionFailure(kind: .userCancelled, engine: TranscriptionEngine.deepgram.displayName).diagnosticCode
        )
        XCTAssertTrue(row.isUserCancelled)
        XCTAssertEqual(row.engine, "Deepgram Nova-3")

        let historyId = try XCTUnwrap(outcome.historyId)
        XCTAssertGreaterThan(historyId, 0)
        XCTAssertEqual(historyId, row.id)
        XCTAssertTrue(outcome.preservedAudio)

        let historyCopy = try XCTUnwrap(outcome.audioURL)
        XCTAssertNotEqual(historyCopy, source, "the outcome must point at the history copy, not the source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyCopy.path))
        XCTAssertTrue(manager.referencedAudioPaths().contains(historyCopy.path))

        XCTAssertEqual(deleteSpy.deleted, [source], "only the source WAV is cleaned up after the copy")

        // Esc must NOT arm Retry.
        XCTAssertNil(persister.lastFailedAudioURL)
        XCTAssertNil(persister.lastFailedHistoryId)
    }

    func testAbortStoringRetryStatePointsAtHistoryCopy() throws {
        let source = makeSourceWAV(named: "abort-retry")

        let outcome = persister.persistAbortedCapture(
            audioURL: source,
            duration: 5.0,
            engine: .deepgram,
            engineName: "Deepgram Nova-3",
            language: "es",
            failureKind: .recordingInterrupted,
            storeRetryState: true
        )

        XCTAssertEqual(persister.lastFailedHistoryId, outcome.historyId)
        XCTAssertEqual(persister.lastFailedAudioURL, outcome.audioURL)
        XCTAssertNotEqual(persister.lastFailedAudioURL, source)
        let retryAudio = try XCTUnwrap(persister.lastFailedAudioURL)
        XCTAssertTrue(manager.referencedAudioPaths().contains(retryAudio.path))
    }

    // MARK: - Retry targets

    func testFailedRetryKeepsOriginalRowUntouched() throws {
        let source = makeSourceWAV(named: "failed")
        persister.persistFailed(
            audioURL: source,
            engine: .deepgram,
            engineName: "Deepgram Nova-3",
            language: "es",
            duration: 3.0,
            failure: TranscriptionFailure(kind: .serverError, engine: "Deepgram"),
            target: .insertNew
        )
        let originalRows = manager.fetchAll()
        XCTAssertEqual(originalRows.count, 1)
        let originalId = try XCTUnwrap(persister.lastFailedHistoryId)
        let retryAudio = try XCTUnwrap(persister.lastFailedAudioURL)

        persister.persistFailed(
            audioURL: retryAudio,
            engine: .mlxWhisper,
            engineName: "MLX Whisper",
            language: "es",
            duration: 3.0,
            failure: TranscriptionFailure(kind: .network),
            target: .updateExisting(historyId: originalId)
        )

        let rows = manager.fetchAll()
        XCTAssertEqual(rows.count, 1, "a failed retry must not insert a new row")
        XCTAssertEqual(rows.first, originalRows.first, "a failed retry must not touch the original row")
        XCTAssertEqual(persister.lastFailedHistoryId, originalId)
        XCTAssertEqual(persister.lastFailedAudioURL, retryAudio, "retry state stays armed for another retry")
    }

    func testCompletedRetryUpdatesRowInPlaceAndClearsRetryState() throws {
        let source = makeSourceWAV(named: "retry-completes")
        persister.persistFailed(
            audioURL: source,
            engine: .deepgram,
            engineName: "Deepgram Nova-3",
            language: "es",
            duration: 3.0,
            failure: TranscriptionFailure(kind: .serverError, engine: "Deepgram"),
            target: .insertNew
        )
        let failedId = try XCTUnwrap(persister.lastFailedHistoryId)
        let retryAudio = try XCTUnwrap(persister.lastFailedAudioURL)

        let aiResult = TranscriptAIResult(
            rawText: "hola mundo",
            finalText: "Hola mundo.",
            status: .applied,
            model: "test-model",
            mode: "automatic",
            error: nil,
            elapsedMs: 1
        )
        persister.persistCompleted(
            audioURL: retryAudio,
            engine: .mlxWhisper,
            engineName: "MLX Whisper",
            language: "es",
            duration: 3.0,
            aiResult: aiResult,
            perf: nil,
            target: .updateExisting(historyId: failedId)
        )

        let rows = manager.fetchAll()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, failedId)
        XCTAssertEqual(row.status, "completed")
        XCTAssertNil(row.failureCode)
        XCTAssertEqual(row.engine, "MLX Whisper", "the retry may run on a different engine")
        XCTAssertEqual(row.text, "Hola mundo.")
        XCTAssertEqual(persister.lastCompletedHistoryId, failedId)
        XCTAssertNil(persister.lastFailedAudioURL)
        XCTAssertNil(persister.lastFailedHistoryId)
    }

    // MARK: - Pre-persisted pending rows

    func testPersistPendingInsertsTranscribingRowAndCleansSource() throws {
        let source = makeSourceWAV(named: "pending")

        let pending = try XCTUnwrap(
            persister.persistPending(
                audioURL: source,
                engine: .localAIServer,
                engineName: "Local AI Server · test-model",
                language: "es",
                duration: 12.5
            ))

        let rows = manager.fetchAll()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, pending.historyId)
        XCTAssertEqual(row.status, "transcribing")
        XCTAssertEqual(row.engine, "Local AI Server · test-model")
        XCTAssertEqual(row.duration, 12.5, accuracy: 0.01)
        XCTAssertTrue(row.text.isEmpty)

        XCTAssertNotEqual(pending.audioURL, source, "the engine must read the History copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.audioURL.path))
        XCTAssertTrue(manager.referencedAudioPaths().contains(pending.audioURL.path))
        XCTAssertEqual(deleteSpy.deleted, [source], "the temp WAV is cleaned once the copy exists")
    }

    func testFinalizePendingSuccessFillsRowInPlace() throws {
        let source = makeSourceWAV(named: "pending-success")
        let pending = try XCTUnwrap(
            persister.persistPending(
                audioURL: source,
                engine: .localAIServer,
                engineName: "Local AI Server · test-model",
                language: "es",
                duration: 4.0
            ))

        let aiResult = TranscriptAIResult(
            rawText: "hola",
            finalText: "Hola.",
            status: .applied,
            model: "test-model",
            mode: "automatic",
            error: nil,
            elapsedMs: 1
        )
        persister.persistCompleted(
            audioURL: pending.audioURL,
            engine: .localAIServer,
            engineName: "Local AI Server · test-model",
            language: "es",
            duration: 4.0,
            aiResult: aiResult,
            perf: nil,
            target: .finalizePending(historyId: pending.historyId)
        )

        let rows = manager.fetchAll()
        XCTAssertEqual(rows.count, 1, "finalizing must not insert a second row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, "completed")
        XCTAssertNil(row.failureCode)
        XCTAssertEqual(row.text, "Hola.")
        XCTAssertEqual(persister.lastCompletedHistoryId, pending.historyId)
    }

    func testFinalizePendingFailureMarksRowFailedAndArmsRetry() throws {
        let source = makeSourceWAV(named: "pending-failure")
        let pending = try XCTUnwrap(
            persister.persistPending(
                audioURL: source,
                engine: .localAIServer,
                engineName: "Local AI Server · test-model",
                language: "es",
                duration: 4.0
            ))
        let deletesAfterPersist = deleteSpy.deleted.count

        persister.persistFailed(
            audioURL: pending.audioURL,
            engine: .localAIServer,
            engineName: "Local AI Server · test-model",
            language: "es",
            duration: 4.0,
            failure: TranscriptionFailure(kind: .network, engine: "Local AI Server"),
            target: .finalizePending(historyId: pending.historyId)
        )

        let rows = manager.fetchAll()
        XCTAssertEqual(rows.count, 1, "failure must resolve the pending row, not insert another")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, "failed")
        XCTAssertEqual(row.failureCode, "Local AI Server/network")
        XCTAssertTrue(row.audioFileExists, "the pre-persisted audio survives the failure")

        XCTAssertEqual(persister.lastFailedHistoryId, pending.historyId)
        XCTAssertEqual(persister.lastFailedAudioURL, pending.audioURL)
        XCTAssertEqual(deleteSpy.deleted.count, deletesAfterPersist, "no audio is deleted on failure")
    }

    func testStaleCleanupNeverDeletesHistoryOwnedAudio() throws {
        let source = makeSourceWAV(named: "pending-stale")
        let pending = try XCTUnwrap(
            persister.persistPending(
                audioURL: source,
                engine: .localAIServer,
                engineName: "Local AI Server · test-model",
                language: "es",
                duration: 4.0
            ))
        // Cancel path: retry state is cleared, then the cancelled pipeline's
        // stale completion asks to clean up the History-owned WAV.
        persister.clearRetryState()
        let deletesAfterPersist = deleteSpy.deleted.count

        persister.cleanUpStaleAudio(pending.audioURL)

        XCTAssertEqual(deleteSpy.deleted.count, deletesAfterPersist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.audioURL.path))
    }

    /// When the History copy fails the row deliberately keeps pointing
    /// at the TEMP WAV, which fails the directory-ownership test — stale cleanup
    /// must consult the row references before deleting the only audio left.
    func testStaleCleanupKeepsTempAudioAHistoryRowReferences() throws {
        let fileManager = FileManager.default
        let blockedDir = fileManager.temporaryDirectory
            .appendingPathComponent("persister-copy-blocked-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: blockedDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: blockedDir) }
        // A regular file where HistoryAudioStorage wants its directory: every
        // copy into History storage fails, like a full or read-only disk.
        fileManager.createFile(atPath: blockedDir.appendingPathComponent("audio").path, contents: Data())

        let blockedManager = TranscriptionHistoryManager(
            databasePath: ":memory:", audioDirectory: blockedDir)
        let spy = DeleteSpy()
        let blockedPersister = DictationHistoryPersister(historyManager: blockedManager) { spy.record($0) }

        let tempWAV = blockedDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        fileManager.createFile(atPath: tempWAV.path, contents: Data(repeating: 0, count: 2048))

        let pending = try XCTUnwrap(
            blockedPersister.persistPending(
                audioURL: tempWAV,
                engine: .localAIServer,
                engineName: "Local AI Server · test-model",
                language: "es",
                duration: 3.0
            ))
        XCTAssertEqual(
            pending.audioURL.path, tempWAV.path,
            "a failed history copy leaves the row on the temp WAV"
        )

        blockedPersister.clearRetryState()
        blockedPersister.cleanUpStaleAudio(pending.audioURL)

        XCTAssertEqual(
            spy.deleted, [], "stale cleanup deleted the only audio the History row points at")
        XCTAssertTrue(try XCTUnwrap(blockedManager.fetchAll().first).audioFileExists)
    }

    /// The reference scan is the only thing that keeps a row-referenced temp
    /// WAV alive here, so a truncated scan must stop the delete instead of
    /// degrading to "nothing is referenced".
    func testStaleCleanupKeepsAudioWhenTheReferenceScanCannotFinish() throws {
        let source = makeSourceWAV(named: "unproven")
        persister.clearRetryState()

        sqlite3_progress_handler(manager.db, 1, { _ in 1 }, nil)
        persister.cleanUpStaleAudio(source)
        XCTAssertEqual(
            deleteSpy.deleted, [],
            "stale cleanup deleted audio on a reference scan that never completed"
        )

        sqlite3_progress_handler(manager.db, 0, nil, nil)
        persister.cleanUpStaleAudio(source)
        XCTAssertEqual(
            deleteSpy.deleted, [source],
            "the guard must skip the delete, not disable it"
        )
    }

    // MARK: - Stale cleanup

    func testStaleCleanupNeverDeletesRetryAudio() throws {
        let source = makeSourceWAV(named: "stale")
        persister.persistFailed(
            audioURL: source,
            engine: .deepgram,
            engineName: "Deepgram Nova-3",
            language: "es",
            duration: 3.0,
            failure: TranscriptionFailure(kind: .serverError, engine: "Deepgram"),
            target: .insertNew
        )
        let retryAudio = try XCTUnwrap(persister.lastFailedAudioURL)
        let deletesAfterPersist = deleteSpy.deleted.count

        persister.cleanUpStaleAudio(retryAudio)
        XCTAssertEqual(deleteSpy.deleted.count, deletesAfterPersist, "the retry audio must survive stale cleanup")

        let other = tempAudioDir.appendingPathComponent("other-\(UUID().uuidString).wav")
        persister.cleanUpStaleAudio(other)
        XCTAssertEqual(deleteSpy.deleted.count, deletesAfterPersist + 1)
        XCTAssertEqual(deleteSpy.deleted.last, other)
    }

    // MARK: - Helpers

    private func makeSourceWAV(named name: String) -> URL {
        let url = tempAudioDir.appendingPathComponent("source-\(name)-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 2048))
        return url
    }
}
