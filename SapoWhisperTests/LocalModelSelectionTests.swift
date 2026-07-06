import XCTest

@testable import SapoWhisper

/// Regression tests for the local-model selection lifecycle: deleting the
/// selected model clears the selection, and switching engines never starts a
/// model download on its own — downloads only follow an explicit user action
/// (model pick, download button, onboarding chip).
@MainActor
final class LocalModelSelectionTests: XCTestCase {

    private var previousEngine: String?
    private var previousModel: String?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousEngine = defaults.string(forKey: Constants.StorageKeys.transcriptionEngine)
        previousModel = defaults.string(forKey: Constants.StorageKeys.mlxWhisperModel)
        // Cloud engine so the ViewModel init never kicks off a local load.
        defaults.set(
            TranscriptionEngine.deepgram.rawValue,
            forKey: Constants.StorageKeys.transcriptionEngine
        )
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        restore(previousEngine, key: Constants.StorageKeys.transcriptionEngine, defaults: defaults)
        restore(previousModel, key: Constants.StorageKeys.mlxWhisperModel, defaults: defaults)
        super.tearDown()
    }

    private func restore(_ value: String?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Model deletion is real (Application Support of the host app), so a
    /// fixture tier must be skipped whenever it is genuinely on disk.
    private func skipIfReallyDownloaded(
        _ model: MLXWhisperModel, in viewModel: SapoWhisperViewModel
    ) throws {
        try XCTSkipIf(
            viewModel.mlxWhisperTranscriber.isModelDownloaded(model),
            "\(model.rawValue) is really downloaded on this machine; skipping to avoid deleting it"
        )
    }

    private func makeViewModel(selecting model: MLXWhisperModel) throws -> SapoWhisperViewModel {
        UserDefaults.standard.set(model.rawValue, forKey: Constants.StorageKeys.mlxWhisperModel)
        let viewModel = SapoWhisperViewModel()
        try skipIfReallyDownloaded(model, in: viewModel)
        return viewModel
    }

    func testDeletingSelectedModelClearsSelection() throws {
        let viewModel = try makeViewModel(selecting: .largeV3)

        viewModel.deleteMLXWhisperModel(.largeV3)

        XCTAssertNil(viewModel.currentMLXWhisperModel)
    }

    func testDeletingUnselectedModelKeepsSelection() throws {
        let viewModel = try makeViewModel(selecting: .largeV3)
        try skipIfReallyDownloaded(.small, in: viewModel)

        viewModel.deleteMLXWhisperModel(.small)

        XCTAssertEqual(viewModel.currentMLXWhisperModel, .largeV3)
    }

    func testSwitchingToLocalEngineDoesNotAutoDownload() throws {
        let viewModel = try makeViewModel(selecting: .largeV3)

        viewModel.setEngine(.mlxWhisper)

        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isAnyDownloadActive)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isLoading)
        if case .noModel = viewModel.appState {
        } else {
            XCTFail("expected .noModel for a selection that is not on disk, got \(viewModel.appState)")
        }
    }

    /// The reported bug end to end: delete the selected model, hop to a cloud
    /// engine, come back to local — nothing may re-download by itself.
    func testDeletedSelectionSurvivesEngineRoundTripWithoutDownload() throws {
        let viewModel = try makeViewModel(selecting: .largeV3)

        viewModel.deleteMLXWhisperModel(.largeV3)
        viewModel.setEngine(.deepgram)
        viewModel.setEngine(.mlxWhisper)

        XCTAssertNil(viewModel.currentMLXWhisperModel)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isAnyDownloadActive)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isLoading)
    }
}
