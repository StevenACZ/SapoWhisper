import Foundation
import XCTest

@testable import SapoWhisper

@MainActor
final class MLXDownloadLifecycleTests: XCTestCase {
    private enum FixtureError: Error { case failed }

    @MainActor
    private final class Downloads {
        var progress: [@MainActor @Sendable (Double) -> Void] = []
        var continuations: [CheckedContinuation<URL, Error>] = []
        var events: [String] = []

        func run(_ model: MLXWhisperModel, root: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
            events.append("download")
            self.progress.append(progress)
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Lifecycle did not reach the expected state")
        throw FixtureError.failed
    }

    func testPauseResumeRejectsOldProgressAndSuccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = Downloads()
        let transcriber = MLXWhisperTranscriber(rootDirectory: root, download: downloads.run)
        var completions = 0
        transcriber.onDownloadCompleted = { _ in completions += 1 }
        transcriber.startDownload(.largeV3)
        try await waitUntil { downloads.continuations.count == 1 }
        downloads.progress[0](0.25)
        transcriber.pauseDownload(.largeV3)
        transcriber.startDownload(.largeV3)
        downloads.progress[0](0.8)
        XCTAssertEqual(transcriber.downloadPhase(.largeV3), .downloading(0.25))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(downloads.continuations.count, 1)
        downloads.continuations[0].resume(returning: root)
        try await waitUntil { downloads.continuations.count == 2 }
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(transcriber.downloadedModels.contains(.largeV3))
        downloads.progress[1](0.4)
        downloads.progress[0](0.95)
        XCTAssertEqual(transcriber.downloadPhase(.largeV3), .downloading(0.4))
        downloads.continuations[1].resume(returning: root)
        try await waitUntil { completions == 1 }
        XCTAssertTrue(transcriber.downloadedModels.contains(.largeV3))
    }

    func testOldFailureDoesNotReplaceResumedPhase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = Downloads()
        let transcriber = MLXWhisperTranscriber(rootDirectory: root, download: downloads.run)
        transcriber.startDownload(.base)
        try await waitUntil { downloads.continuations.count == 1 }
        transcriber.pauseDownload(.base)
        transcriber.startDownload(.base)
        downloads.continuations[0].resume(throwing: FixtureError.failed)
        try await waitUntil { downloads.continuations.count == 2 }
        XCTAssertEqual(transcriber.downloadPhase(.base), .downloading(0))
        downloads.continuations[1].resume(returning: root)
        try await waitUntil { transcriber.downloadedModels.contains(.base) }
    }

    func testCancelDeleteRedownloadWaitsForOldWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = Downloads()
        let transcriber = MLXWhisperTranscriber(
            rootDirectory: root, download: downloads.run,
            delete: { _, _ in downloads.events.append("delete") }
        )
        transcriber.startDownload(.small)
        try await waitUntil { downloads.continuations.count == 1 }
        transcriber.cancelDownload(.small)
        transcriber.startDownload(.small)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(downloads.events, ["download"])
        downloads.continuations[0].resume(returning: root)
        try await waitUntil { downloads.continuations.count == 2 }
        XCTAssertEqual(downloads.events, ["download", "delete", "download"])
        XCTAssertFalse(transcriber.downloadedModels.contains(.small))
        downloads.continuations[1].resume(returning: root)
        try await waitUntil { transcriber.downloadedModels.contains(.small) }
    }

    func testSelectingStandaloneDownloadThenPausingDoesNotRestartIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = Downloads()
        let transcriber = MLXWhisperTranscriber(rootDirectory: root, download: downloads.run)
        transcriber.startDownload(.base)
        try await waitUntil { downloads.continuations.count == 1 }
        downloads.progress[0](0.3)
        let load = Task { try await transcriber.loadModel(.base) }
        try await waitUntil { transcriber.loadingState == .downloading }
        transcriber.pauseDownload(.base)
        downloads.continuations[0].resume(returning: root)
        try await waitUntil { !transcriber.isLoading || downloads.continuations.count > 1 }
        if downloads.continuations.count > 1 {
            downloads.continuations[1].resume(throwing: CancellationError())
        }
        do {
            try await load.value
            XCTFail("Pausing must cancel the joined load")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected load error: \(error)")
        }
        XCTAssertEqual(downloads.continuations.count, 1)
        XCTAssertEqual(transcriber.downloadPhase(.base), .paused(0.3))
        XCTAssertFalse(transcriber.isModelLoaded)
        XCTAssertFalse(transcriber.downloadedModels.contains(.base))
    }

    func testDeletionFailureRemainsVisibleAndPreservesDownloadedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transcriber = MLXWhisperTranscriber(
            rootDirectory: root, delete: { _, _ in throw FixtureError.failed }
        )
        transcriber.downloadedModels.insert(.largeV3Turbo)
        transcriber.deleteDownloadedModel(.largeV3Turbo)
        try await waitUntil { transcriber.errorMessage != nil }
        guard case .failed = transcriber.downloadPhase(.largeV3Turbo) else {
            return XCTFail("Deletion failure must remain visible")
        }
        XCTAssertTrue(transcriber.downloadedModels.contains(.largeV3Turbo))
    }

    func testConfigureLaterPausesAndPreservesSelectionWithoutLateReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = Downloads()
        let transcriber = MLXWhisperTranscriber(rootDirectory: root, download: downloads.run)
        let viewModel = SapoWhisperViewModel(mlxWhisperTranscriber: transcriber)
        let previousEngine = viewModel.selectedEngine
        let previousModel = viewModel.selectedMLXWhisperModel
        defer {
            viewModel.selectedEngine = previousEngine
            viewModel.selectedMLXWhisperModel = previousModel
        }
        viewModel.selectedMLXWhisperModel = MLXWhisperModel.base.rawValue
        viewModel.setEngine(.mlxWhisper)
        transcriber.startDownload(.base)
        try await waitUntil { downloads.continuations.count == 1 }
        downloads.progress[0](0.3)
        transcriber.isLoading = true
        viewModel.deferMLXWhisperModelSetup()
        XCTAssertEqual(transcriber.downloadPhase(.base), .paused(0.3))
        XCTAssertEqual(viewModel.currentMLXWhisperModel, .base)
        XCTAssertFalse(transcriber.isLoading)
        XCTAssertFalse(viewModel.isEngineReady(.mlxWhisper))
        downloads.continuations[0].resume(returning: root)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transcriber.isModelLoaded)
        XCTAssertFalse(transcriber.downloadedModels.contains(.base))
        XCTAssertEqual(transcriber.downloadPhase(.base), .paused(0.3))
    }

}
