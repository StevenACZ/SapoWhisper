//
//  DictationHistoryPersisterTests.swift
//  SapoWhisperTests
//
//  Persistence state machine for live dictations: aborted captures become
//  cancelled/failed rows pointing at the HISTORY audio copy, retries update
//  rows in place, failed retries keep the original row, and stale cleanup
//  never deletes the retry audio.
//

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
