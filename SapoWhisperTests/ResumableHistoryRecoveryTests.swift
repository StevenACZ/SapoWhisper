import AVFoundation
import SQLite3
import XCTest

@testable import SapoWhisper

@MainActor
final class ResumableHistoryRecoveryTests: XCTestCase {
    private var directory: URL!
    private var manager: TranscriptionHistoryManager!
    private let now = Date(timeIntervalSince1970: 1_788_480_000)

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resumable-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: directory)
    }

    override func tearDown() async throws {
        manager = nil
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCancelledTakeReappearsOnRepeatedLaunchRecovery() throws {
        let id = try saveTake(reason: "Local AI Server/user_cancelled", age: 120, duration: 600)

        for _ in 0..<2 {
            XCTAssertNil(manager.recoverInterruptedTranscriptions())
            let offer = try XCTUnwrap(manager.latestResumableDictation(now: now))
            XCTAssertEqual(offer.historyId, id)
            XCTAssertEqual(offer.duration, 600)
            XCTAssertEqual(offer.capturedAt, now.addingTimeInterval(-120))
            XCTAssertTrue(FileManager.default.fileExists(atPath: offer.audioURL.path))
        }
    }

    func testInterruptedTranscriptionRemainsOfferedAfterSecondLaunch() throws {
        let id = try saveTake(reason: nil, age: 60, status: "transcribing")

        XCTAssertEqual(manager.recoverInterruptedTranscriptions()?.id, id)
        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, id)
        XCTAssertNil(manager.recoverInterruptedTranscriptions())
        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, id)
    }

    func testRecoveryAndCaptureInterruptionReasonsAreEligible() throws {
        let recovered = try saveTake(reason: OrphanAudioRecovery.failureCode, age: 120)
        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, recovered)
        let interrupted = try saveTake(reason: "Deepgram/recording_interrupted", age: 60)
        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, interrupted)
    }

    func testNewestExistingAudioWinsAndTiesUseNewestID() throws {
        _ = try saveTake(reason: "?/user_cancelled", age: 120)
        let eligible = try saveTake(reason: "?/user_cancelled", age: 120)
        let missing = try saveTake(reason: "?/user_cancelled", age: 60)
        let missingPath = try XCTUnwrap(manager.entry(id: missing)?.audioPath)
        try FileManager.default.removeItem(atPath: missingPath)

        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, eligible)
    }

    func testCompletedAndDeletedTakesAreNotOffered() throws {
        let completed = try saveTake(reason: "?/user_cancelled", age: 120)
        manager.updateStatus(id: completed, status: "completed", transcription: "Synthetic test result")
        XCTAssertNil(manager.latestResumableDictation(now: now))

        let deleted = try saveTake(reason: "?/user_cancelled", age: 60)
        manager.delete(id: deleted)
        XCTAssertNil(manager.latestResumableDictation(now: now))
    }

    func testExpiredMissingAndUnrelatedFailuresAreExcluded() throws {
        _ = try saveTake(reason: "?/user_cancelled", age: 30 * 60)
        _ = try saveTake(reason: "?/recording_interrupted", age: 30 * 60 + 1)
        for reason in ["Deepgram/network", "?/userXcancelled", "?/recordingXinterrupted", "Other/recovered_after_crash"] {
            _ = try saveTake(reason: reason, age: 60)
        }
        _ = try saveTake(reason: nil, age: 60)
        let missing = try saveTake(reason: "?/user_cancelled", age: 60)
        let missingPath = try XCTUnwrap(manager.entry(id: missing)?.audioPath)
        try FileManager.default.removeItem(atPath: missingPath)

        XCTAssertNil(manager.latestResumableDictation(now: now))
    }

    func testTakeJustInsideWindowIsOffered() throws {
        let id = try saveTake(reason: "?/user_cancelled", age: 30 * 60 - 1)
        XCTAssertEqual(manager.latestResumableDictation(now: now)?.historyId, id)
    }

    private func saveTake(
        reason: String?, age: TimeInterval, duration: TimeInterval = 300, status: String = "failed"
    ) throws -> Int64 {
        let audioURL = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try writeWAV(to: audioURL)
        let id = manager.save(
            engine: "Test", language: "auto", duration: duration, text: "",
            audioPath: audioURL.path, status: status, failureCode: reason
        )
        XCTAssertGreaterThan(id, 0)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            sqlite3_prepare_v2(manager.db, "UPDATE transcriptions SET timestamp = ? WHERE id = ?;", -1, &statement, nil),
            SQLITE_OK
        )
        manager.bindText(statement, 1, TranscriptionHistoryManager.isoFormatter.string(from: now.addingTimeInterval(-age)))
        sqlite3_bind_int64(statement, 2, id)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        return id
    }

    private func writeWAV(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
