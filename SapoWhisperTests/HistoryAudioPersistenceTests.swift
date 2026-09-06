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

@MainActor
final class HistoryAudioPersistenceTests: XCTestCase {

    private var manager: TranscriptionHistoryManager!
    private var tempAudioDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempAudioDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-audio-tests-\(UUID().uuidString)")
        manager = TranscriptionHistoryManager(databasePath: ":memory:", audioDirectory: tempAudioDir)
    }

    override func tearDown() async throws {
        manager = nil
        if let tempAudioDir {
            try? FileManager.default.removeItem(at: tempAudioDir)
        }
        try await super.tearDown()
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

    // MARK: - Corrupt database recovery

    /// Recovery sidelines the corrupt DB and opens an empty schema, so
    /// every stored WAV instantly looks orphaned. The audio must be sidelined
    /// with it — otherwise the first sweep (every save, plus the launch
    /// auto-delete) erases every recording the user ever made.
    func testCorruptDatabaseRecoverySidelinesAudioInsteadOfSweepingIt() throws {
        let fileManager = FileManager.default
        let appDir = fileManager.temporaryDirectory
            .appendingPathComponent("history-corrupt-tests-\(UUID().uuidString)", isDirectory: true)
        let audioDir = appDir.appendingPathComponent("audio", isDirectory: true)
        try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: appDir) }

        let databasePath = appDir.appendingPathComponent("history.db").path
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: databasePath))
        let recordings = (0..<2).map { _ in "audio_\(UUID().uuidString).wav" }
        for name in recordings {
            fileManager.createFile(
                atPath: audioDir.appendingPathComponent(name).path,
                contents: Data(repeating: 0, count: 2048)
            )
        }

        let recovered = TranscriptionHistoryManager(databasePath: databasePath, audioDirectory: appDir)

        let appDirContents = try fileManager.contentsOfDirectory(atPath: appDir.path)
        XCTAssertTrue(
            appDirContents.contains { $0.hasPrefix("history.db.corrupt-") },
            "the corrupt DB itself must be sidelined"
        )
        let sidelinedName = try XCTUnwrap(
            appDirContents.first { $0.hasPrefix("audio.corrupt-") },
            "the audio of the corrupt DB must be sidelined, not left for the orphan sweep"
        )
        let sidelinedDir = appDir.appendingPathComponent(sidelinedName, isDirectory: true)
        XCTAssertEqual(
            Set(try fileManager.contentsOfDirectory(atPath: sidelinedDir.path)), Set(recordings))
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: audioDir.path), [],
            "recovery starts from an empty audio directory"
        )

        // The very next dictation runs the orphan sweep; the sidelined audio is
        // outside its directory and must survive.
        let source = appDir.appendingPathComponent("post-recovery-\(UUID().uuidString).wav")
        fileManager.createFile(atPath: source.path, contents: Data(repeating: 0, count: 2048))
        let result = recovered.persistEntry(
            audioSource: source, engine: "Deepgram", language: "es", duration: 1, text: "after recovery"
        )
        XCTAssertGreaterThan(result.rowID, 0, "the recreated schema must accept new rows")
        recovered.enforceAudioStorageLimit()

        for name in recordings {
            XCTAssertTrue(
                fileManager.fileExists(atPath: sidelinedDir.appendingPathComponent(name).path),
                "the orphan sweep deleted a recording the corrupt DB referenced: \(name)"
            )
        }
    }

    /// Sidelined audio is unreachable for every other delete path, so its own
    /// window is the only thing that stops repeated corruptions from filling
    /// the disk. Recent sidelines must survive it.
    func testSidelinedAudioExpiresAfterItsRetentionWindow() throws {
        let fileManager = FileManager.default
        let appDir = fileManager.temporaryDirectory
            .appendingPathComponent("history-sideline-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: appDir) }

        let now = Date()
        let expiredStamp = Int(now.timeIntervalSince1970 - HistoryAudioStorage.sidelinedRetention - 60)
        let freshStamp = Int(now.timeIntervalSince1970 - 60)
        for stamp in [expiredStamp, freshStamp] {
            let directory = appDir.appendingPathComponent("audio.corrupt-\(stamp)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            fileManager.createFile(
                atPath: directory.appendingPathComponent("audio_kept.wav").path,
                contents: Data(repeating: 0, count: 2048)
            )
        }

        let storage = HistoryAudioStorage(appDirectory: appDir)
        storage.pruneSidelinedAudio(now: now)

        let remaining = try fileManager.contentsOfDirectory(atPath: appDir.path)
            .filter { $0.hasPrefix("audio.corrupt-") }
        XCTAssertEqual(remaining, ["audio.corrupt-\(freshStamp)"])
    }

    // MARK: - Helpers

    private func makeSourceWAV(named name: String) -> URL {
        let url = tempAudioDir.appendingPathComponent("source-\(name)-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 2048))
        return url
    }
}
