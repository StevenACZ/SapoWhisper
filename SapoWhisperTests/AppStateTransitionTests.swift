//
//  AppStateTransitionTests.swift
//  SapoWhisperTests
//

import MLXWhisper
import XCTest

@testable import SapoWhisper

/// Pins the dictation state machine's legality table: every edge the real
/// flows take must be legal, and the clobber patterns the ViewModel's guards
/// were written against must not be.
@MainActor
final class AppStateTransitionTests: XCTestCase {

    private let error = AppState.error(ErrorState(message: "boom"))

    func testRealFlowEdgesAreLegal() {
        // Live dictation: start → stop → polish → deliver.
        XCTAssertTrue(AppState.idle.canTransition(to: .recording))
        XCTAssertTrue(AppState.recording.canTransition(to: .processing))
        XCTAssertTrue(AppState.processing.canTransition(to: .polishing))
        XCTAssertTrue(AppState.polishing.canTransition(to: .idle))

        // Failure surfaces from any stage; retry restarts from error or idle.
        XCTAssertTrue(AppState.recording.canTransition(to: error))
        XCTAssertTrue(AppState.processing.canTransition(to: error))
        XCTAssertTrue(AppState.polishing.canTransition(to: error))
        XCTAssertTrue(error.canTransition(to: .processing))
        XCTAssertTrue(AppState.idle.canTransition(to: .processing))

        // Repolish runs from the completed pill; no-speech resets processing.
        XCTAssertTrue(AppState.idle.canTransition(to: .polishing))
        XCTAssertTrue(AppState.processing.canTransition(to: .idle))

        // Cloud engines record without a local model; model install recovers.
        XCTAssertTrue(AppState.noModel.canTransition(to: .recording))
        XCTAssertTrue(AppState.noModel.canTransition(to: .idle))
        XCTAssertTrue(AppState.idle.canTransition(to: .noModel))
    }

    func testPublishersMayReEmitCurrentState() {
        XCTAssertTrue(AppState.recording.canTransition(to: .recording))
        XCTAssertTrue(AppState.processing.canTransition(to: .processing))
        XCTAssertTrue(error.canTransition(to: AppState.error(ErrorState(message: "other"))))
    }

    func testClobberEdgesAreIllegal() {
        // The "never clobber an active session" comments, as a table.
        XCTAssertFalse(AppState.processing.canTransition(to: .recording))
        XCTAssertFalse(AppState.polishing.canTransition(to: .recording))
        XCTAssertFalse(AppState.polishing.canTransition(to: .processing))
        XCTAssertFalse(AppState.recording.canTransition(to: .noModel))
        XCTAssertFalse(AppState.polishing.canTransition(to: .noModel))
        XCTAssertFalse(AppState.recording.canTransition(to: .polishing))
        XCTAssertFalse(AppState.noModel.canTransition(to: .polishing))
    }
}

/// The same table enforced on the live ViewModel: the readiness recompute
/// (`checkInitialState`) reaches `appState` from Settings paths that a user can
/// trigger mid-dictation, and must leave an owned session alone.
@MainActor
final class DictationSessionGuardTests: XCTestCase {

    private let defaults = AppPreferences.defaults
    private var restore: [String: String?] = [:]

    private static var largeV3SnapshotDirectory: URL {
        WhisperModelDownloader.modelDirectory(
            repo: MLXWhisperModel.largeV3.rawValue,
            root: MLXWhisperTranscriber.modelsRootDirectory
        )
    }

    private func set(_ value: String, forKey key: String) {
        if restore[key] == nil {
            restore[key] = .some(defaults.string(forKey: key))
        }
        defaults.set(value, forKey: key)
    }

    override func setUp() async throws {
        try await super.setUp()
        // A cloud primary with no backup keeps ViewModel init off the local
        // model loader; the mode/engine keys are captured for restore here.
        set(TranscriptionEngine.deepgram.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set("", forKey: Constants.StorageKeys.fallbackTranscriptionEngine)
        set(DeepgramTranscriptionMode.nova3.rawValue, forKey: Constants.StorageKeys.deepgramTranscriptionMode)
        set(
            ElevenLabsTranscriptionMode.defaultMode.rawValue,
            forKey: Constants.StorageKeys.elevenLabsTranscriptionMode
        )
        set(MLXWhisperModel.largeV3.rawValue, forKey: Constants.StorageKeys.mlxWhisperModel)
    }

    override func tearDown() async throws {
        for (key, previous) in restore {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        restore = [:]
        // A test that parks the ViewModel in .recording emitted a `.began` to
        // the companion contract; close the pair so no listener stays ducked.
        DictationStateBroadcaster.broadcastRecordingEnded()
        try await super.tearDown()
    }

    /// Drives `appState` to `.recording` the way a real capture does — through
    /// the recorder's publisher — without opening a microphone.
    private func makeRecordingViewModel() -> SapoWhisperViewModel {
        let viewModel = SapoWhisperViewModel()
        viewModel.activeRecordingSessionID = 1
        viewModel.audioRecorder.isRecordingPublisher.send(true)
        return viewModel
    }

    private func endCapture(_ viewModel: SapoWhisperViewModel) {
        viewModel.audioRecorder.isRecordingPublisher.send(false)
    }

    /// DeepgramSettingsCard and ElevenLabsSettingsCard call these setters from
    /// `onAppear`, so merely opening the Engine tab while dictating used to end
    /// the session and broadcast a false `.ended`.
    func testEngineTabSettersKeepAnActiveRecording() {
        let viewModel = makeRecordingViewModel()
        defer { endCapture(viewModel) }
        XCTAssertEqual(viewModel.appState, .recording)

        viewModel.setDeepgramMode(.fluxLive)
        XCTAssertEqual(viewModel.appState, .recording, "setDeepgramMode ended the dictation")

        viewModel.setElevenLabsMode(.scribeV2Realtime)
        XCTAssertEqual(viewModel.appState, .recording, "setElevenLabsMode ended the dictation")

        viewModel.setEngine(.elevenLabsScribe)
        XCTAssertEqual(viewModel.appState, .recording, "setEngine ended the dictation")
    }

    /// The transcription window: `stopRecordingAndTranscribe` clears the
    /// recording session id and takes a transcription one, so a guard that only
    /// checks the former leaves the whole decode unprotected.
    func testDeletingTheSelectedModelKeepsAnActiveTranscription() throws {
        set(TranscriptionEngine.mlxWhisper.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)

        let viewModel = makeRecordingViewModel()
        defer { endCapture(viewModel) }
        // The delete removes the tier's snapshot directory from the app's real
        // Application Support root, and an incomplete snapshot does not count
        // as downloaded, so absence on disk is the only safe precondition.
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: Self.largeV3SnapshotDirectory.path),
            "a largeV3 snapshot exists on this machine; skipping to avoid deleting real files"
        )
        viewModel.activeRecordingSessionID = nil
        viewModel.activeTranscriptionSessionID = 1

        viewModel.deleteMLXWhisperModel(.largeV3)

        XCTAssertEqual(viewModel.appState, .recording, "the delete clobbered the transcription session")
        XCTAssertNil(viewModel.currentMLXWhisperModel)
    }

    /// The guard defers the readiness recompute, it does not disable it.
    func testReadinessRecomputeResumesOnceTheSessionEnds() {
        let viewModel = makeRecordingViewModel()
        defer { endCapture(viewModel) }
        XCTAssertEqual(viewModel.appState, .recording)

        viewModel.activeRecordingSessionID = nil
        viewModel.setEngine(.elevenLabsScribe)

        XCTAssertNotEqual(viewModel.appState, .recording)
    }
}
