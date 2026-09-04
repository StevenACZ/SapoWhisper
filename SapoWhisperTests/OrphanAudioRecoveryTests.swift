//
//  OrphanAudioRecoveryTests.swift
//  SapoWhisperTests
//
//  Guards the crash-recovery path: an abandoned dictation WAV in the temp
//  directory becomes a retranscribable failed History row at launch, with the
//  interrupted writer's stale RIFF/data sizes repaired in place.
//

import SQLite3
import XCTest

@testable import SapoWhisper

@MainActor
final class OrphanAudioRecoveryTests: XCTestCase {

    private var tempDir: URL!
    private var manager: TranscriptionHistoryManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempDir)
    }

    override func tearDown() async throws {
        manager = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func testRecoversStaleHeaderOrphanIntoFailedRow() throws {
        let orphan = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        try writeWAV(to: orphan, seconds: 5, staleHeader: true)
        try backdate(orphan, by: 300)

        let recovery = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(recovery.latest?.duration ?? 0, 5.0, accuracy: 0.1)
        let entries = manager.fetchAll()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.status, "failed")
        XCTAssertEqual(entry.failureCode, OrphanAudioRecovery.failureCode)
        XCTAssertEqual(entry.duration, 5.0, accuracy: 0.1)
        XCTAssertTrue(entry.audioFileExists)
        // Source orphan was moved into history storage.
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRepairsStaleHeaderInPlace() throws {
        let wav = tempDir.appendingPathComponent("recording_repair.wav")
        try writeWAV(to: wav, seconds: 3, staleHeader: true)

        let first = try XCTUnwrap(WAVHeaderRepair.repairIfNeeded(at: wav))
        XCTAssertTrue(first.repairedHeader)
        XCTAssertEqual(first.duration, 3.0, accuracy: 0.1)

        // Second pass sees consistent sizes and does not rewrite.
        let second = try XCTUnwrap(WAVHeaderRepair.repairIfNeeded(at: wav))
        XCTAssertFalse(second.repairedHeader)
        XCTAssertEqual(second.duration, 3.0, accuracy: 0.1)
    }

    func testSkipsNonRecoverableFiles() throws {
        // Fresh file: could belong to a live session.
        let fresh = tempDir.appendingPathComponent("recording_fresh.wav")
        try writeWAV(to: fresh, seconds: 5, staleHeader: false)

        // Too short to be worth a row.
        let short = tempDir.appendingPathComponent("recording_short.wav")
        try writeWAV(to: short, seconds: 0.4, staleHeader: false)
        try backdate(short, by: 300)

        // Mic-test prefix is not a dictation.
        let micTest = tempDir.appendingPathComponent("mic_test_raw_x.wav")
        try writeWAV(to: micTest, seconds: 5, staleHeader: false)
        try backdate(micTest, by: 300)

        // Already referenced by a history row.
        let referenced = tempDir.appendingPathComponent("recording_referenced.wav")
        try writeWAV(to: referenced, seconds: 5, staleHeader: false)
        try backdate(referenced, by: 300)
        manager.save(
            engine: "Test", language: "auto", duration: 5, text: "x",
            audioPath: referenced.path, status: "failed"
        )

        let recovery = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovery.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: short.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micTest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertEqual(manager.fetchAll().count, 1)
    }

    func testDeadOwnerMarkerRecoversFreshWAVImmediately() throws {
        // Fresh WAV (no backdate) that the old 60 s age gate would skip, but
        // its active-recording marker names a dead PID → instant adoption.
        let orphan = tempDir.appendingPathComponent("recording_marked.wav")
        try writeWAV(to: orphan, seconds: 4, staleHeader: true)
        let marker = ActiveRecordingMarker.markerURL(for: orphan)
        try "99999999".write(to: marker, atomically: true, encoding: .utf8)

        let recovery = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(manager.fetchAll().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "dead marker must be cleaned up")
    }

    func testLiveOwnerMarkerProtectsFreshWAV() throws {
        // PID 1 (launchd) always reads as alive → the WAV belongs to a live
        // session and must not be stolen.
        let active = tempDir.appendingPathComponent("recording_live.wav")
        try writeWAV(to: active, seconds: 4, staleHeader: true)
        let marker = ActiveRecordingMarker.markerURL(for: active)
        try "1".write(to: marker, atomically: true, encoding: .utf8)

        let recovery = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovery.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "live marker must stay")
    }

    func testCurrentProcessMarkerProtectsFreshWAVUntilCleared() throws {
        let wav = tempDir.appendingPathComponent("recording_roundtrip.wav")
        try writeWAV(to: wav, seconds: 1, staleHeader: false)

        ActiveRecordingMarker.mark(wav)
        let marker = ActiveRecordingMarker.markerURL(for: wav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(ActiveRecordingMarker.ownerIsAlive(markerURL: marker))
        XCTAssertTrue(ActiveRecordingMarker.abandonedRecordings(in: tempDir).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        ActiveRecordingMarker.clear(wav)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - Helpers

    /// Builds a 16 kHz mono int16 WAV. `staleHeader: true` mimics an
    /// interrupted AVAudioFile writer: samples on disk, sizes still 0.
    // MARK: - Interrupted-transcription sweep (pre-persisted rows)

    func testRecoverInterruptedTranscriptionsResolvesStuckRows() throws {
        let source = tempDir.appendingPathComponent("interrupted-source.wav")
        try writeWAV(to: source, seconds: 4, staleHeader: false)
        let persisted = manager.persistEntry(
            audioSource: source,
            engine: "Local AI Server",
            language: "es",
            duration: 42,
            text: "",
            status: "transcribing"
        )
        XCTAssertGreaterThan(persisted.rowID, 0)

        let latest = manager.recoverInterruptedTranscriptions()

        XCTAssertEqual(latest?.id, persisted.rowID)
        XCTAssertEqual(latest?.audioPath, persisted.audioPath)
        XCTAssertEqual(latest?.duration ?? 0, 42, accuracy: 0.1)
        let entry = try XCTUnwrap(manager.fetchAll().first)
        XCTAssertEqual(entry.status, "failed")
        XCTAssertEqual(
            entry.failureCode, TranscriptionHistoryManager.interruptedTranscriptionFailureCode)
        XCTAssertTrue(entry.audioFileExists, "the pre-persisted audio survives the app dying")
    }

    func testRecoverInterruptedTranscriptionsIgnoresResolvedRows() {
        manager.persistEntry(
            audioSource: nil, engine: "e", language: "es", duration: 1,
            text: "hola", status: "completed")
        manager.persistEntry(
            audioSource: nil, engine: "e", language: "es", duration: 1,
            text: "", status: "failed", failureCode: "Engine/network")

        XCTAssertNil(manager.recoverInterruptedTranscriptions())
        let statuses = manager.fetchAll().map(\.status).sorted()
        XCTAssertEqual(statuses, ["completed", "failed"])
    }

    // MARK: - Stale temp sweep vs. History references

    /// The 24h temp sweep deletes by age alone, but a History row can
    /// point at a temp WAV (the persist copy-failure path). Referenced files
    /// survive; unreferenced stale ones still go.
    func testStaleSweepKeepsHistoryReferencedTempAudio() throws {
        let sweepDir = tempDir.appendingPathComponent("temp-sweep", isDirectory: true)
        try FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)

        let referenced = sweepDir.appendingPathComponent("recording_referenced.wav")
        try writeWAV(to: referenced, seconds: 5, staleHeader: false)
        try backdate(referenced, by: 48 * 60 * 60)
        let abandoned = sweepDir.appendingPathComponent("recording_abandoned.wav")
        try writeWAV(to: abandoned, seconds: 5, staleHeader: false)
        try backdate(abandoned, by: 48 * 60 * 60)

        manager.save(
            engine: "Test", language: "auto", duration: 5, text: "x",
            audioPath: referenced.path, status: "failed"
        )
        let referencedNames = Set(
            manager.referencedAudioPaths().map { ($0 as NSString).lastPathComponent }
        )

        TemporaryAudioStorage.sweepStaleFiles(in: sweepDir, referencedNames: referencedNames)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: referenced.path),
            "the sweep deleted a WAV the History still references"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: abandoned.path),
            "an unreferenced stale WAV must still be swept"
        )
    }

    func testStaleSweepKeepsMarkedStreamingAudioAndSidecar() throws {
        let sweepDir = tempDir.appendingPathComponent("temp-sweep-marked", isDirectory: true)
        try FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)

        let marked = sweepDir.appendingPathComponent("flux_recording_marked.wav")
        try writeWAV(to: marked, seconds: 5, staleHeader: false)
        let marker = ActiveRecordingMarker.markerURL(for: marked)
        try "1".write(to: marker, atomically: true, encoding: .utf8)
        try backdate(marked, by: 48 * 60 * 60)
        try backdate(marker, by: 48 * 60 * 60)

        let removed = TemporaryAudioStorage.sweepStaleFiles(
            in: sweepDir,
            referencedNames: []
        )

        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A truncated reference scan is indistinguishable from "nothing is
    /// referenced", which is exactly the state that makes the sweep delete the
    /// last copy of a dictation.
    func testStaleSweepDeletesNothingWhenTheReferenceScanCannotFinish() throws {
        let sweepDir = tempDir.appendingPathComponent("temp-sweep-unproven", isDirectory: true)
        try FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)

        let referenced = sweepDir.appendingPathComponent("recording_referenced.wav")
        try writeWAV(to: referenced, seconds: 5, staleHeader: false)
        try backdate(referenced, by: 48 * 60 * 60)

        manager.save(
            engine: "Test", language: "auto", duration: 5, text: "x",
            audioPath: referenced.path, status: "failed"
        )

        sqlite3_progress_handler(manager.db, 1, { _ in 1 }, nil)
        defer { sqlite3_progress_handler(manager.db, 0, nil, nil) }
        let referencedNames = manager.referencedAudioPathsIfComplete().map { paths in
            Set(paths.map { ($0 as NSString).lastPathComponent })
        }

        XCTAssertNil(referencedNames, "the interrupted scan must not report a complete set")
        XCTAssertEqual(TemporaryAudioStorage.sweepStaleFiles(in: sweepDir, referencedNames: referencedNames), 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: referenced.path),
            "the sweep ran on a reference scan that never completed"
        )
    }

    private func writeWAV(to url: URL, seconds: TimeInterval, staleHeader: Bool) throws {
        let sampleRate: UInt32 = 16_000
        let byteRate = sampleRate * 2
        let dataSize = UInt32(TimeInterval(byteRate) * seconds)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(&data, staleHeader ? 0 : 36 + dataSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)  // PCM
        appendUInt16(&data, 1)  // mono
        appendUInt32(&data, sampleRate)
        appendUInt32(&data, byteRate)
        appendUInt16(&data, 2)  // block align
        appendUInt16(&data, 16)  // bits per sample
        data.append(contentsOf: "data".utf8)
        appendUInt32(&data, staleHeader ? 0 : dataSize)
        data.append(Data(count: Int(dataSize)))
        try data.write(to: url)
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func backdate(_ url: URL, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: url.path
        )
    }
}
