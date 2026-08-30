import Foundation
import Testing

@testable import SapoWhisper

@Suite("Stop capture feedback ordering")
struct StopCaptureFeedbackOrderingTests {
    private actor SealProbe {
        private var sealCalls = 0
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func seal() async {
            sealCalls += 1
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func recordSecondTeardown() {
            sealCalls += 1
        }

        func callCount() -> Int {
            sealCalls
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private actor StartCompletionProbe {
        private var isBlocked = false
        private var continuation: CheckedContinuation<Void, Never>?

        func finishStartWhenReleased() async {
            await withCheckedContinuation {
                continuation = $0
                isBlocked = true
            }
        }

        func waitUntilBlocked() async {
            while !isBlocked {
                await Task.yield()
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SapoWhisper/Core")

    @Test("Stop sound runs only after every capture is sealed")
    func feedbackFollowsCaptureStop() throws {
        let viewModel = try source("SapoWhisperViewModel.swift")
        let requestBody = try body(
            in: viewModel,
            from: "private func requestStopAndTranscribe(",
            to: "nonisolated static func stopTailPadding"
        )
        #expect(!requestBody.contains("SoundManager.shared.play"))

        let batchTail = try #require(
            viewModel.range(of: "seal: { await audioRecorder.stopRecordingAsync() }")
        )
        let batchTransition = try #require(
            viewModel.range(
                of: "completeCaptureStopTransition(sessionID: sessionID, perf: perf)",
                range: batchTail.upperBound..<viewModel.endIndex
            )
        )
        #expect(batchTail.lowerBound < batchTransition.lowerBound)

        for fileName in ["DeepgramFluxLiveTranscriber.swift", "ElevenLabsScribeRealtimeTranscriber.swift"] {
            let transcriber = try source(fileName)
            let stopBody = try body(in: transcriber, from: "func stop(", to: "func cancel()")
            let captureStop = try #require(stopBody.range(of: "capture.stopRecording()"))
            let feedback = try #require(stopBody.range(of: "onStopped: onCaptureStopped"))
            #expect(captureStop.lowerBound < feedback.lowerBound)
        }
    }

    @Test("Batch capture awaits async teardown before feedback")
    @MainActor
    func executableCaptureHandoff() async {
        var events: [String] = []
        let value = await BatchStopCaptureHandoff.perform(
            seal: {
                events.append("seal-started")
                await Task.yield()
                events.append("seal-finished")
                return 42
            },
            onStopped: {
                events.append("feedback")
            }
        )

        #expect(value == 42)
        #expect(events == ["seal-started", "seal-finished", "feedback"])
    }

    @Test("Sleep during async sealing shares one teardown and one feedback")
    @MainActor
    func interruptionDuringAsyncSeal() async {
        let probe = SealProbe()
        var feedbackCount = 0
        let stopTask = Task { @MainActor in
            await BatchStopCaptureHandoff.perform(
                seal: {
                    await probe.seal()
                    return 42
                },
                onStopped: { feedbackCount += 1 }
            )
        }

        while await probe.callCount() == 0 {
            await Task.yield()
        }

        let sharesSeal = CaptureStopInterruptionGate.sharesInFlightSeal(
            isStopPending: true,
            hasPendingTailTask: false
        )
        if !sharesSeal {
            await probe.recordSecondTeardown()
        }

        await probe.release()
        let value = await stopTask.value

        #expect(sharesSeal)
        #expect(value == 42)
        #expect(await probe.callCount() == 1)
        #expect(feedbackCount == 1)
        #expect(
            !CaptureStopInterruptionGate.sharesInFlightSeal(
                isStopPending: true,
                hasPendingTailTask: true
            )
        )
    }

    @Test("Sleep and quit after the seal never invoke the transcription engine")
    @MainActor
    func terminalDispositionSkipsEngine() async {
        var persistedResults: [Int] = []
        var engineCalls = 0

        for disposition in [BatchStopTerminalDisposition.sleep, .terminate] {
            await BatchStopTerminalRouter.perform(
                sealedResult: 42,
                disposition: disposition,
                onTerminal: { result, _ in
                    if let result {
                        persistedResults.append(result)
                    }
                },
                onContinue: { _ in
                    engineCalls += 1
                }
            )
        }

        #expect(persistedResults == [42, 42])
        #expect(engineCalls == 0)
    }

    @Test("Cancel at start completion discards the newly opened capture")
    @MainActor
    func cancelWinsAtStartCompletion() async {
        let probe = StartCompletionProbe()
        var sessionIsCurrent = true
        var captureIsActive = false
        var abortCalls = 0

        let task = Task { @MainActor in
            try? await CaptureStartCompletionGate.perform(
                start: {
                    await probe.finishStartWhenReleased()
                    captureIsActive = true
                },
                isSessionCurrent: { sessionIsCurrent },
                abortStarted: {
                    abortCalls += 1
                    captureIsActive = false
                }
            )
        }

        await probe.waitUntilBlocked()
        sessionIsCurrent = false
        task.cancel()
        await probe.release()
        let accepted = await task.value

        #expect(accepted == false)
        #expect(abortCalls == 1)
        #expect(!captureIsActive)
    }

    @Test("Lifecycle interruptions are routed through the post-seal terminal gate")
    func lifecycleTerminalRoutingIsWired() throws {
        let viewModel = try source("SapoWhisperViewModel.swift")
        let sleepBody = try body(
            in: viewModel,
            from: "func handleSystemWillSleep()",
            to: "func handleApplicationWillTerminate()"
        )
        let terminateBody = try body(
            in: viewModel,
            from: "func handleApplicationWillTerminate()",
            to: "private func handleCaptureDeviceFailure"
        )
        let stopBody = try body(
            in: viewModel,
            from: "private func stopRecordingAndTranscribe(",
            to: "private func processStoppedBatchCapture("
        )

        #expect(sleepBody.contains("pendingBatchStopTerminalDisposition = .sleep"))
        #expect(terminateBody.contains("pendingBatchStopTerminalDisposition = .terminate"))
        #expect(stopBody.contains("BatchStopTerminalRouter.perform"))
    }

    @Test("Sleep cancels a pending tail before preserving capture")
    func sleepCancelsPendingTail() throws {
        let viewModel = try source("SapoWhisperViewModel.swift")
        let sleepBody = try body(
            in: viewModel,
            from: "func handleSystemWillSleep()",
            to: "func handleApplicationWillTerminate()"
        )
        let cancellation = try #require(sleepBody.range(of: "cancelPendingStopTail()"))
        let preservation = try #require(sleepBody.range(of: "abortActiveCapturePreservingAudio"))
        #expect(cancellation.lowerBound < preservation.lowerBound)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(in source: String, from start: String, to end: String) throws -> String {
        let suffix = try #require(source.components(separatedBy: start).dropFirst().first)
        return try #require(suffix.components(separatedBy: end).first)
    }
}
