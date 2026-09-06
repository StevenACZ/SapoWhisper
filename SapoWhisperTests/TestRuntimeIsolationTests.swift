import Foundation
import SQLite3
import XCTest

@testable import SapoWhisper

@MainActor
final class TestRuntimeIsolationTests: XCTestCase {
    func testPreferencesDoNotWriteToTheApplicationDomain() {
        XCTAssertTrue(UIPreviewMode.isRunningTests)
        let key = "isolation-probe-\(UUID().uuidString)"
        AppPreferences.defaults.set("fixture", forKey: key)
        defer { AppPreferences.defaults.removeObject(forKey: key) }
        XCTAssertEqual(AppPreferences.defaults.string(forKey: key), "fixture")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testSharedHistoryModelsAndAudioUseTheIsolatedRoot() throws {
        XCTAssertTrue(AppRuntimePaths.isIsolated)
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let support = AppRuntimePaths.applicationSupport.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(support.hasPrefix(temporary))
        XCTAssertTrue(AppRuntimePaths.temporaryAudio.path.contains("SapoWhisperTests-"))
        XCTAssertTrue(MLXWhisperTranscriber.modelsRootDirectory.path.hasPrefix(AppRuntimePaths.applicationSupport.path))
        let manager = TranscriptionHistoryManager.shared
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(manager.db, "PRAGMA database_list", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let databaseName = try XCTUnwrap(sqlite3_column_text(statement, 2))
        let databasePath = String(cString: databaseName)
        let databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(databaseURL.deletingLastPathComponent().path, support)
        XCTAssertEqual(databaseURL.lastPathComponent, "history.db")
    }
}
