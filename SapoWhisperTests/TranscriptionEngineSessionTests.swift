import XCTest

@testable import SapoWhisper

/// Characterization tests for the read-only engine-state surface introduced to
/// retire the duplicated `switch currentEngine` (deferred refactor, plan step
/// 2). They pin the aggregation semantics the ViewModel now derives from
/// `EngineSessions` — readiness comes from the single readiness session, busy
/// is OR-ed across every session, and `canRecord` is `ready && !busy` behind
/// the active-session / app-busy guards — so the refactor is provably
/// behavior-preserving. The live-sibling-busy case mirrors the historical
/// guard that a Deepgram/ElevenLabs engine blocks recording while its Flux /
/// Realtime session is mid-flight.
@MainActor
final class TranscriptionEngineSessionTests: XCTestCase {

    /// Controllable stand-in for a concrete transcriber. The real live sessions
    /// keep `isStreaming`/`isStopping` as `private(set)`, so a fake is the only
    /// way to exercise the busy-sibling combinations deterministically.
    private final class FakeSession: TranscriptionEngineSession {
        var isReady: Bool
        var isBusy: Bool
        init(isReady: Bool = false, isBusy: Bool = false) {
            self.isReady = isReady
            self.isBusy = isBusy
        }
    }

    // MARK: - isReady

    func testIsReadyReflectsOnlyTheReadinessSession() {
        let ready = FakeSession(isReady: true)
        let notReady = FakeSession(isReady: false)

        // A ready sibling must not make the engine ready when the readiness
        // session itself is not ready...
        XCTAssertFalse(EngineSessions(readiness: notReady, busy: [notReady, ready]).isReady)
        // ...and the readiness session alone decides it.
        XCTAssertTrue(EngineSessions(readiness: ready, busy: [ready, notReady]).isReady)
    }

    // MARK: - isBusy

    func testIsBusyOrsAcrossEverySession() {
        let idle = FakeSession()
        let busy = FakeSession(isBusy: true)

        XCTAssertFalse(EngineSessions(readiness: idle, busy: [idle, idle]).isBusy)
        // Primary (readiness) session busy.
        XCTAssertTrue(EngineSessions(readiness: busy, busy: [busy, idle]).isBusy)
        // Live sibling busy while the primary is idle (the Flux / Realtime case).
        XCTAssertTrue(EngineSessions(readiness: idle, busy: [idle, busy]).isBusy)
    }

    // MARK: - canRecord

    /// A ready, idle engine with one live sibling, matching the real shape of
    /// the cloud engines (batch readiness session + live sibling).
    private func makeReadyEngine(siblingBusy: Bool = false) -> EngineSessions {
        let primary = FakeSession(isReady: true, isBusy: false)
        let sibling = FakeSession(isReady: true, isBusy: siblingBusy)
        return EngineSessions(readiness: primary, busy: [primary, sibling])
    }

    func testCanRecordWhenReadyIdleAndUnguarded() {
        XCTAssertTrue(
            makeReadyEngine().canRecord(hasActiveTranscriptionSession: false, appIsBusyProcessing: false)
        )
    }

    func testCanRecordBlockedByActiveTranscriptionSession() {
        XCTAssertFalse(
            makeReadyEngine().canRecord(hasActiveTranscriptionSession: true, appIsBusyProcessing: false)
        )
    }

    func testCanRecordBlockedWhileAppIsBusyProcessing() {
        XCTAssertFalse(
            makeReadyEngine().canRecord(hasActiveTranscriptionSession: false, appIsBusyProcessing: true)
        )
    }

    func testCanRecordBlockedWhenEngineNotReady() {
        let notReady = FakeSession(isReady: false, isBusy: false)
        let sessions = EngineSessions(readiness: notReady, busy: [notReady])
        XCTAssertFalse(
            sessions.canRecord(hasActiveTranscriptionSession: false, appIsBusyProcessing: false)
        )
    }

    func testCanRecordBlockedWhenPrimaryBusy() {
        let busyPrimary = FakeSession(isReady: true, isBusy: true)
        let sessions = EngineSessions(readiness: busyPrimary, busy: [busyPrimary])
        XCTAssertFalse(
            sessions.canRecord(hasActiveTranscriptionSession: false, appIsBusyProcessing: false)
        )
    }

    func testCanRecordBlockedWhenLiveSiblingBusy() {
        // Readiness session is ready & idle, but a live sibling is mid-flight:
        // the historical guard blocked a new recording here, and still must.
        XCTAssertFalse(
            makeReadyEngine(siblingBusy: true)
                .canRecord(hasActiveTranscriptionSession: false, appIsBusyProcessing: false)
        )
    }

    // MARK: - Conformance mapping (deterministic engine)

    /// WhisperKit is the one engine whose readiness/busy inputs are plain
    /// `@Published var`s, so its conformance can be pinned end to end without
    /// the keychain / `private(set)` constraints of the cloud engines.
    func testWhisperKitSessionMapsModelLoadedAndTranscribing() {
        let transcriber = WhisperKitTranscriber()
        XCTAssertFalse(transcriber.isReady, "no model loaded yet")
        XCTAssertFalse(transcriber.isBusy)

        transcriber.isModelLoaded = true
        XCTAssertTrue(transcriber.isReady)

        transcriber.isTranscribing = true
        XCTAssertTrue(transcriber.isBusy)
    }

    // MARK: - VM mapping (composition pinned against accidental edits)

    /// Pins the single `switch` that maps a logical engine to its concrete
    /// sessions. The pure-logic tests above can't catch a future edit that
    /// drops `deepgramFluxTranscriber` / `elevenLabsRealtimeTranscriber` from
    /// the `busy` array — this does, by object identity. It touches no keychain
    /// and no `private(set)` live state, only composition. The engine is forced
    /// to a cloud value first so the ViewModel's init does not kick off a
    /// WhisperKit model load.
    func testEngineSessionsMapEachEngineToItsConcreteTranscribers() {
        let defaults = UserDefaults.standard
        let key = Constants.StorageKeys.transcriptionEngine
        let previous = defaults.string(forKey: key)
        defaults.set(TranscriptionEngine.deepgram.rawValue, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let viewModel = SapoWhisperViewModel()

        let whisper = viewModel.engineSessions(for: .whisperLocal)
        XCTAssertTrue(whisper.readiness === viewModel.whisperKitTranscriber)
        XCTAssertEqual(whisper.busy.count, 1)
        XCTAssertTrue(whisper.busy.contains { $0 === viewModel.whisperKitTranscriber })

        let deepgram = viewModel.engineSessions(for: .deepgram)
        XCTAssertTrue(deepgram.readiness === viewModel.deepgramTranscriber)
        XCTAssertTrue(deepgram.busy.contains { $0 === viewModel.deepgramTranscriber })
        XCTAssertTrue(
            deepgram.busy.contains { $0 === viewModel.deepgramFluxTranscriber },
            "Deepgram must keep its Flux live session in the busy set"
        )

        let eleven = viewModel.engineSessions(for: .elevenLabsScribe)
        XCTAssertTrue(eleven.readiness === viewModel.elevenLabsTranscriber)
        XCTAssertTrue(eleven.busy.contains { $0 === viewModel.elevenLabsTranscriber })
        XCTAssertTrue(
            eleven.busy.contains { $0 === viewModel.elevenLabsRealtimeTranscriber },
            "ElevenLabs must keep its Realtime session in the busy set"
        )
    }
}
