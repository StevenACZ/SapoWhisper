import XCTest

@testable import SapoWhisper

@MainActor
final class ConcurrentPostProcessingTests: XCTestCase {
    private final class Processor: TranscriptPostProcessing {
        var decisions: [String: Bool] = [:]
        var processing: [String: Bool] = [:]
        var historyContinuation: CheckedContinuation<Void, Never>?

        func willAttemptPolish(rawText: String, duration: TimeInterval?, enforceMinimumDuration: Bool) -> Bool {
            decisions[rawText] = enforceMinimumDuration
            return false
        }

        func process(
            rawText: String, duration: TimeInterval?, provider: PolishProviderConfiguration?, enforceMinimumDuration: Bool
        ) async -> TranscriptAIResult {
            processing[rawText] = enforceMinimumDuration
            if rawText == "history input" {
                await withCheckedContinuation { historyContinuation = $0 }
            }
            return TranscriptAIResult(
                rawText: rawText, finalText: rawText, status: .none, model: nil,
                mode: nil, error: nil, elapsedMs: 0
            )
        }
    }

    func testHistoryAndLiveProcessingKeepIndependentDurationPolicies() async {
        let defaults = AppPreferences.defaults
        let engineKey = Constants.StorageKeys.transcriptionEngine
        let previous = defaults.object(forKey: engineKey)
        defaults.set(TranscriptionEngine.deepgram.rawValue, forKey: engineKey)
        defer { defaults.set(previous, forKey: engineKey) }
        let processor = Processor()
        let viewModel = SapoWhisperViewModel(transcriptPostProcessor: processor)
        let history = Task {
            await viewModel.postProcessTranscript("history input", source: "test-history", duration: 2, context: .history)
        }
        for _ in 0..<100 where processor.historyContinuation == nil { await Task.yield() }
        XCTAssertNotNil(processor.historyContinuation)

        let live = await viewModel.postProcessTranscript("live input", source: "test-live", duration: 2)

        XCTAssertEqual(live.finalText, "live input")
        XCTAssertEqual(processor.decisions, ["history input": false, "live input": true])
        XCTAssertEqual(processor.processing, ["history input": false, "live input": true])
        processor.historyContinuation?.resume()
        _ = await history.value
    }
}
