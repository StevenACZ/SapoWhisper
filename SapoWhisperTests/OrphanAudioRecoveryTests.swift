//
//  OrphanAudioRecoveryTests.swift
//  SapoWhisperTests
//
//  Guards the crash-recovery path: an abandoned dictation WAV in the temp
//  directory becomes a retranscribable failed History row at launch, with the
//  interrupted writer's stale RIFF/data sizes repaired in place.
//

import XCTest

@testable import SapoWhisper

final class OrphanAudioRecoveryTests: XCTestCase {

    private var tempDir: URL!
    private var manager: TranscriptionHistoryManager!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempDir)
    }

    override func tearDown() {
        manager = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRecoversStaleHeaderOrphanIntoFailedRow() throws {
        let orphan = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        try writeWAV(to: orphan, seconds: 5, staleHeader: true)
        try backdate(orphan, by: 300)

        let recovered = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovered, 1)
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

        let recovered = OrphanAudioRecovery.recoverAbandonedRecordings(in: tempDir, historyManager: manager)

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: short.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micTest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertEqual(manager.fetchAll().count, 1)
    }

    // MARK: - Helpers

    /// Builds a 16 kHz mono int16 WAV. `staleHeader: true` mimics an
    /// interrupted AVAudioFile writer: samples on disk, sizes still 0.
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
