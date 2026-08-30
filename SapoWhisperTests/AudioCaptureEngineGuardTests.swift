//
//  AudioCaptureEngineGuardTests.swift
//  SapoWhisperTests
//
//  AVFAudio teardown (removeTap / stop / reset) raises uncatchable
//  Objective-C exceptions mid route change, so every occurrence in the capture
//  engine must sit inside an AudioEngineGuard block. The crash itself needs a
//  real route transition, so the rule is enforced as a source invariant.
//

@preconcurrency import Combine
import Foundation
import XCTest

@testable import SapoWhisper

nonisolated final class AudioCaptureEngineGuardTests: XCTestCase {

    func testOnlyStreamingCaptureKeepsRecoveryMarkerAfterSeal() {
        XCTAssertFalse(AudioCaptureEngine.Mode.batch.keepsRecoveryMarkerAfterCapture)
        XCTAssertTrue(AudioCaptureEngine.Mode.streaming.keepsRecoveryMarkerAfterCapture)
    }

    private nonisolated final class ResultStore: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<Int, Error>] = []
        private var cleanupValues: [Int] = []
        private var quarantines: [Bool] = []

        func append(result: Result<Int, Error>) {
            lock.withLock { results.append(result) }
        }

        func append(cleanup value: Int) {
            lock.withLock { cleanupValues.append(value) }
        }

        func append(quarantine timedOut: Bool) {
            lock.withLock { quarantines.append(timedOut) }
        }

        var resultCount: Int { lock.withLock { results.count } }
        var cleanup: [Int] { lock.withLock { cleanupValues } }
        var firstResult: Result<Int, Error>? { lock.withLock { results.first } }
        var quarantineEvents: [Bool] { lock.withLock { quarantines } }
    }

    private static let teardownCalls = ["removeTap(onBus:", ".stop()", ".reset()"]

    private static var captureEngineSources: [URL] {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("Core")
        let contents = (try? FileManager.default.contentsOfDirectory(at: coreDirectory, includingPropertiesForKeys: nil)) ?? []
        return
            contents
            .filter { $0.lastPathComponent.hasPrefix("AudioCaptureEngine") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static var audioEngineLifecycleSources: [URL] {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("Core")
        return captureEngineSources + [
            coreDirectory.appendingPathComponent("AudioLevelMonitor.swift"),
            coreDirectory.appendingPathComponent("Managers/AudioInputPreflightManager.swift"),
            coreDirectory.appendingPathComponent("Permissions/MicrophonePermission.swift"),
        ]
    }

    func testCaptureEngineSourcesAreReachable() {
        XCTAssertEqual(
            Self.captureEngineSources.map(\.lastPathComponent),
            [
                "AudioCaptureEngine+Device.swift",
                "AudioCaptureEngine+Diagnostics.swift",
                "AudioCaptureEngine+Processing.swift",
                "AudioCaptureEngine.swift",
            ]
        )
    }

    func testEveryEngineTeardownRunsInsideAudioEngineGuard() throws {
        var violations: [String] = []
        for source in Self.audioEngineLifecycleSources {
            let text = try String(contentsOf: source, encoding: .utf8)
            violations += Self.unguardedTeardowns(in: text, file: source.lastPathComponent)
        }

        XCTAssertEqual(violations, [], "AVAudioEngine teardown outside AudioEngineGuard at \(violations.joined(separator: ", "))")
    }

    func testEveryTeardownCallOwnsItsGuardBlock() throws {
        var violations: [String] = []
        for source in Self.audioEngineLifecycleSources {
            let text = try String(contentsOf: source, encoding: .utf8)
            violations += Self.teardownsSharingAGuard(in: text, file: source.lastPathComponent)
        }

        XCTAssertEqual(
            violations, [],
            "a raised removeTap would skip the stop/reset sharing its guard at \(violations.joined(separator: ", "))"
        )
    }

    func testRetirementWaitsForEngineAndRouteQuiescence() {
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: 0,
                routeSettleDelay: 0
            ),
            AudioEngineRetirementPool.quietPeriod
        )
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: AudioEngineRetirementPool.quietPeriod + 1,
                routeSettleDelay: 1.25
            ),
            1.25
        )
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: AudioEngineRetirementPool.quietPeriod + 1,
                routeSettleDelay: 0
            ),
            0
        )
    }

    func testDeadlineWinsAndLateSuccessCleansUpOnce() {
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-timeout",
            work: {
                workStarted.signal()
                releaseWork.wait()
                return 7
            },
            cleanup: {
                store.append(cleanup: $0)
                cleaned.signal()
            },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(workStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        guard case .failure(let error) = store.firstResult else {
            return XCTFail("expected deadline failure")
        }
        guard case .inputSetupTimedOut = error as? RecordingError else {
            return XCTFail("unexpected error: \(error)")
        }

        releaseWork.signal()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.resultCount, 1)
        XCTAssertEqual(store.cleanup, [7])
    }

    func testSuccessWinsDeadlineWithoutCleanup() {
        let completed = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 1,
            operation: "test-success",
            work: { 9 },
            cleanup: { store.append(cleanup: $0) },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        guard case .success(let value) = store.firstResult else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(value, 9)
        XCTAssertTrue(store.cleanup.isEmpty)
    }

    func testCancellationWinsAndLateSuccessCleansUpOnce() {
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let quarantine = AudioInputSetupQuarantine()
        let epoch = quarantine.currentEpoch
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 1,
            operation: "test-cancel",
            work: {
                workStarted.signal()
                releaseWork.wait()
                return 11
            },
            cleanup: {
                store.append(cleanup: $0)
                cleaned.signal()
            },
            onQuarantine: {
                store.append(quarantine: $0)
                quarantine.quarantine(epoch: epoch)
            },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(workStarted.wait(timeout: .now() + 1), .success)
        attempt.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        guard case .failure(let error) = store.firstResult else {
            return XCTFail("expected cancellation")
        }
        XCTAssertTrue(error is CancellationError)
        releaseWork.signal()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.resultCount, 1)
        XCTAssertEqual(store.cleanup, [11])
        XCTAssertTrue(store.quarantineEvents.isEmpty)
        XCTAssertTrue(quarantine.canAttempt(epoch: epoch))
    }

    func testCancelledBlockedWorkerQuarantinesAtOriginalDeadline() {
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let quarantined = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let quarantine = AudioInputSetupQuarantine()
        let epoch = quarantine.currentEpoch
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-cancel-blocked",
            work: {
                workStarted.signal()
                releaseWork.wait()
                return 19
            },
            cleanup: {
                store.append(cleanup: $0)
                cleaned.signal()
            },
            onQuarantine: {
                store.append(quarantine: $0)
                quarantine.quarantine(epoch: epoch)
                quarantined.signal()
            },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(workStarted.wait(timeout: .now() + 1), .success)
        attempt.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(quarantined.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(quarantine.canAttempt(epoch: epoch))
        XCTAssertEqual(store.resultCount, 1)
        XCTAssertEqual(store.quarantineEvents, [true])
        releaseWork.signal()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.cleanup, [19])
        XCTAssertEqual(store.resultCount, 1)
    }

    func testCancellationBeforeWorkerStartsDoesNotQuarantine() {
        let worker = DispatchQueue(label: "test.audio.deadline.suspended")
        worker.suspend()
        let completed = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-cancel-before-work",
            worker: worker,
            work: { 13 },
            cleanup: { store.append(cleanup: $0) },
            onQuarantine: { store.append(quarantine: $0) },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        attempt.cancel()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.06)
        XCTAssertTrue(store.quarantineEvents.isEmpty)
        worker.resume()
        XCTAssertTrue(store.cleanup.isEmpty)
    }

    func testTimeoutBeforeWorkerStartsDoesNotQuarantine() {
        let worker = DispatchQueue(label: "test.audio.deadline.timeout-suspended")
        worker.suspend()
        let completed = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let quarantine = AudioInputSetupQuarantine()
        let epoch = quarantine.currentEpoch
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-timeout-before-work",
            worker: worker,
            work: { 23 },
            cleanup: { store.append(cleanup: $0) },
            onQuarantine: {
                store.append(quarantine: $0)
                quarantine.quarantine(epoch: epoch)
            },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        guard case .failure(let error) = store.firstResult else {
            return XCTFail("expected timeout")
        }
        guard case .inputSetupTimedOut = error as? RecordingError else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(quarantine.canAttempt(epoch: epoch))
        XCTAssertTrue(store.quarantineEvents.isEmpty)
        worker.resume()
        XCTAssertTrue(store.cleanup.isEmpty)
        XCTAssertEqual(store.resultCount, 1)
    }

    func testDeadlineCoversInjectedPreparationBlock() {
        let inputMaterialized = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let store = ResultStore()
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-prepare-timeout",
            work: {
                inputMaterialized.signal()
                releasePreparation.wait()
                return 17
            },
            cleanup: {
                store.append(cleanup: $0)
                cleaned.signal()
            },
            onQuarantine: { store.append(quarantine: $0) },
            completion: {
                store.append(result: $0)
                completed.signal()
            }
        )

        attempt.start()
        XCTAssertEqual(inputMaterialized.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        guard case .failure(let error) = store.firstResult else {
            return XCTFail("expected preparation deadline")
        }
        guard case .inputSetupTimedOut = error as? RecordingError else {
            return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(store.quarantineEvents, [true])
        releasePreparation.signal()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(store.cleanup, [17])
        XCTAssertEqual(store.resultCount, 1)
    }

    func testCancelledGenerationIsRejectedBeforeWAVCreation() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper/Core/AudioCaptureEngine.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let phaseStart = try XCTUnwrap(text.range(of: "let tapFormat = materializedInput.tapFormat"))
        let generationGuard = try XCTUnwrap(
            text.range(of: "guard self.isSetupGenerationCurrent(setupGeneration)", range: phaseStart.upperBound..<text.endIndex)
        )
        let wavCreation = try XCTUnwrap(
            text.range(of: "TemporaryAudioStorage.makeWAVURL", range: generationGuard.upperBound..<text.endIndex)
        )
        let sharedStateMutation = try XCTUnwrap(
            text.range(of: "self.audioFile = audioFile", range: wavCreation.upperBound..<text.endIndex)
        )

        XCTAssertLessThan(generationGuard.lowerBound, wavCreation.lowerBound)
        XCTAssertLessThan(generationGuard.lowerBound, sharedStateMutation.lowerBound)
    }

    func testBluetoothOnEitherSideUsesExtendedInputSetupDeadline() {
        XCTAssertEqual(AudioEngineGuard.inputSetupDeadline(inputTransport: .usb, outputTransport: .bluetooth), 5)
        XCTAssertEqual(AudioEngineGuard.inputSetupDeadline(inputTransport: .bluetooth, outputTransport: .builtIn), 5)
        XCTAssertEqual(AudioEngineGuard.inputSetupDeadline(inputTransport: .usb, outputTransport: .builtIn), 3)
    }

    func testTimeoutQuarantineBlocksSameEpochUntilRouteChange() {
        let quarantine = AudioInputSetupQuarantine()
        let epoch = quarantine.currentEpoch

        XCTAssertTrue(quarantine.canAttempt(epoch: epoch))
        quarantine.quarantine(epoch: epoch)
        XCTAssertFalse(quarantine.canAttempt(epoch: epoch))
        quarantine.advanceRouteEpoch()
        XCTAssertTrue(quarantine.canAttempt(epoch: quarantine.currentEpoch))
    }

    func testTimeoutQuarantinesRouteThatIsCurrentWhenDeadlineExpires() {
        let workStarted = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let quarantine = AudioInputSetupQuarantine()
        let attempt = AudioDeadlineAttempt<Int>(
            timeout: 0.03,
            operation: "test-route-change-during-timeout",
            work: {
                workStarted.signal()
                releaseWork.wait()
                return 29
            },
            cleanup: { _ in },
            onQuarantine: { _ in quarantine.quarantineCurrentEpoch() },
            completion: { _ in completed.signal() }
        )

        attempt.start()
        XCTAssertEqual(workStarted.wait(timeout: .now() + 1), .success)
        quarantine.advanceRouteEpoch()
        let currentEpoch = quarantine.currentEpoch
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(quarantine.canAttempt(epoch: currentEpoch))
        releaseWork.signal()
    }

    @MainActor
    func testObservedRouteChangeClearsQuarantine() {
        let quarantine = AudioInputSetupQuarantine()
        let routes = PassthroughSubject<Void, Never>()
        let epoch = quarantine.currentEpoch
        quarantine.observeRouteChanges(routes.eraseToAnyPublisher())
        quarantine.quarantine(epoch: epoch)

        XCTAssertFalse(quarantine.canAttempt(epoch: epoch))
        routes.send(())
        XCTAssertTrue(quarantine.canAttempt(epoch: quarantine.currentEpoch))
        XCTAssertNotEqual(quarantine.currentEpoch, epoch)
    }

    func testTheDetectorFlagsAnUnguardedTeardown() {
        let unguarded = """
            func teardown(engine: AVAudioEngine) {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            """
        let guarded = """
            func teardown(engine: AVAudioEngine) {
                try? AudioEngineGuard.run("teardown") {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            }
            """

        XCTAssertEqual(Self.unguardedTeardowns(in: unguarded, file: "Stub.swift"), ["Stub.swift:2", "Stub.swift:3"])
        XCTAssertEqual(Self.unguardedTeardowns(in: guarded, file: "Stub.swift"), [])
        XCTAssertEqual(Self.teardownsSharingAGuard(in: guarded, file: "Stub.swift"), ["Stub.swift:4"])
        XCTAssertEqual(
            Self.teardownsSharingAGuard(
                in: """
                    try? AudioEngineGuard.run("remove-tap") {
                        engine.inputNode.removeTap(onBus: 0)
                    }
                    try? AudioEngineGuard.run("stop") { engine.stop() }
                    """,
                file: "Stub.swift"
            ),
            []
        )
    }

    private static func teardownsSharingAGuard(in text: String, file: String) -> [String] {
        var violations: [String] = []
        var depth = 0
        var openGuards: [(depth: Int, teardowns: Int)] = []

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = strippingComment(rawLine)
            if line.contains("AudioEngineGuard."), line.contains("{") {
                openGuards.append((depth, 0))
            }
            if !openGuards.isEmpty, teardownCalls.contains(where: { line.contains($0) }) {
                openGuards[openGuards.count - 1].teardowns += 1
                if openGuards[openGuards.count - 1].teardowns > 1 {
                    violations.append("\(file):\(index + 1)")
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            while let last = openGuards.last, depth <= last.depth {
                openGuards.removeLast()
            }
        }
        return violations
    }

    private static func unguardedTeardowns(in text: String, file: String) -> [String] {
        var violations: [String] = []
        var depth = 0
        var guardDepths: [Int] = []

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = strippingComment(rawLine)
            let opensGuard = line.contains("AudioEngineGuard.")
            let guarded = opensGuard || guardDepths.contains { depth > $0 }

            if !guarded, teardownCalls.contains(where: { line.contains($0) }) {
                violations.append("\(file):\(index + 1)")
            }

            if opensGuard, line.contains("{") {
                guardDepths.append(depth)
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            guardDepths.removeAll { depth <= $0 }
        }
        return violations
    }

    private static func strippingComment(_ line: String) -> String {
        guard let marker = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<marker.lowerBound])
    }
}
