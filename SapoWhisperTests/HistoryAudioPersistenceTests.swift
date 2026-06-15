//
//  HistoryAudioPersistenceTests.swift
//  SapoWhisperTests
//
//  Guards the audio-loss race fix: persisting an entry (copy WAV -> insert row)
//  and the orphan/size sweep are serialized through the manager's persistence
//  lock so a concurrent sweep can never delete a freshly copied WAV before its
//  row references it.
//

import XCTest

@testable import SapoWhisper

final class HistoryAudioPersistenceTests: XCTestCase {

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!

    override func setUp() {
        super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-audio-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
    }

    override func tearDown() {
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        super.tearDown()
    }

    // MARK: - Atomic persist

    /// `persistEntry` copies the source WAV into history storage, inserts a row,
    /// and the row's `audio_path` points at a file that still exists (the orphan
    /// sweep inside `save` must not delete the just-copied WAV).
    func testPersistEntryCopiesAudioAndReferencesIt() throws {
        let source = makeSourceWAV(named: "single")

        let result = manager.persistEntry(
            audioSource: source, engine: "Deepgram", language: "es", duration: 1, text: "hola"
        )

        XCTAssertGreaterThan(result.rowID, 0)
        XCTAssertTrue(result.copiedToHistory)
        let savedPath = try XCTUnwrap(result.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedPath))
        XCTAssertTrue(manager.referencedAudioPaths().contains(savedPath))
        // The copy lives in the history audio dir, not the original source path.
        XCTAssertNotEqual(savedPath, source.path)
    }

    /// With no audio source, persistEntry still inserts a row and reports no copy.
    func testPersistEntryWithoutAudioInsertsRow() {
        let result = manager.persistEntry(
            audioSource: nil, engine: "WhisperKit", language: "en", duration: 0.5, text: "no audio"
        )
        XCTAssertGreaterThan(result.rowID, 0)
        XCTAssertFalse(result.copiedToHistory)
        XCTAssertNil(result.audioPath)
    }

    // MARK: - Sweep invariant (deterministic)

    /// The core invariant the persistence lock buys, proven without relying on
    /// concurrency timing: persist many entries, force the orphan/size sweep
    /// directly, and assert every referenced WAV still exists and no row was
    /// dropped.
    func testOrphanSweepKeepsAllReferencedAudio() {
        for index in 0..<25 {
            let source = makeSourceWAV(named: "row-\(index)")
            let result = manager.persistEntry(
                audioSource: source, engine: "Deepgram", language: "es", duration: 1, text: "row \(index)"
            )
            XCTAssertGreaterThan(result.rowID, 0)
        }

        manager.enforceAudioStorageLimit()

        let referenced = manager.referencedAudioPaths()
        XCTAssertEqual(referenced.count, 25, "the sweep must not drop any row's audio")
        for path in referenced {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "the sweep deleted audio still referenced by a row: \(path)"
            )
        }
    }

    // MARK: - Concurrency stress (real threads, not the cooperative pool)

    /// Regression guard for the audio-loss race. Uses `concurrentPerform` (real
    /// GCD threads) rather than a TaskGroup so the blocking persistence lock
    /// cannot starve the Swift concurrency cooperative pool. Many persists race
    /// many orphan sweeps; every referenced WAV must survive.
    func testConcurrentPersistAndSweepNeverOrphansReferencedAudio() {
        let manager = self.manager!
        let dir = self.tempAudioDir!

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            if index.isMultiple(of: 2) {
                let source = dir.appendingPathComponent("src-\(index)-\(UUID().uuidString).wav")
                FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 0, count: 2048))
                _ = manager.persistEntry(
                    audioSource: source, engine: "Deepgram", language: "es",
                    duration: 1, text: "row \(index)"
                )
            } else {
                manager.enforceAudioStorageLimit()
            }
        }

        let referenced = manager.referencedAudioPaths()
        XCTAssertFalse(referenced.isEmpty, "expected rows that reference audio")
        for path in referenced {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "a concurrent sweep deleted referenced audio: \(path)"
            )
        }
    }

    /// Persisting while another thread deletes history must not strand audio
    /// either (the `deleteEntries` sweep shares the persistence lock).
    /// `olderThanDays: 1` never removes the just-inserted recent rows, so the
    /// invariant is asserted against a guaranteed non-empty set.
    func testConcurrentPersistAndDeleteKeepsReferencedAudio() {
        let manager = self.manager!
        let dir = self.tempAudioDir!

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            if index.isMultiple(of: 3) {
                _ = manager.deleteEntries(olderThanDays: 1)
            } else {
                let source = dir.appendingPathComponent("del-\(index)-\(UUID().uuidString).wav")
                FileManager.default.createFile(atPath: source.path, contents: Data(repeating: 0, count: 2048))
                _ = manager.persistEntry(
                    audioSource: source, engine: "Deepgram", language: "es",
                    duration: 1, text: "row \(index)"
                )
            }
        }

        let referenced = manager.referencedAudioPaths()
        XCTAssertFalse(referenced.isEmpty, "recent rows should survive deleteEntries(olderThanDays: 1)")
        for path in referenced {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "a concurrent deleteEntries sweep deleted referenced audio: \(path)"
            )
        }
    }

    // MARK: - Helpers

    private func makeSourceWAV(named name: String) -> URL {
        let url = tempAudioDir.appendingPathComponent("source-\(name)-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 2048))
        return url
    }
}
