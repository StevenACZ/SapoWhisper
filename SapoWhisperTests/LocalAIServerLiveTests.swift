import Foundation
import XCTest

@testable import SapoWhisper

@MainActor
final class LocalAIServerLiveTests: XCTestCase {
    func testFirstTranscriptionOnConfiguredLocalServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SAPO_LOCAL_STT_SMOKE"] == "1" else {
            throw XCTSkip("Explicit local-server fixture opt-in required")
        }
        try XCTSkipUnless(AppRuntimePaths.isIsolated, "Requires an isolated test host")
        let baseURL = try XCTUnwrap(environment["SAPO_LOCAL_STT_SMOKE_BASE_URL"])
        let model = try XCTUnwrap(environment["SAPO_LOCAL_STT_SMOKE_MODEL"])
        let defaults = AppPreferences.defaults
        let keys = [Constants.StorageKeys.localAIServerBaseURL, Constants.StorageKeys.localAIServerModel]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(baseURL, forKey: keys[0])
        defaults.set(model, forKey: keys[1])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/LocalAITranscription/technical/es/synthetic-public.wav")
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await TranscriptionAttemptContext.$prefersConfiguredBackup.withValue(true) {
            try await LocalAIServerTranscriber().transcribe(audioURL: fixture, language: "es")
        }
        XCTAssertGreaterThan(result.trimmingCharacters(in: .whitespacesAndNewlines).count, 10)
        print(
            "local-first-request pid=\(ProcessInfo.processInfo.processIdentifier) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) chars=\(result.count)"
        )
    }
}
