@testable import SapoWhisper
import XCTest

/// Regression tests for the local-model selection lifecycle: deleting the
/// selected model clears the selection, and switching engines never starts a
/// model download on its own — downloads only follow an explicit user action
/// (model pick, download button, onboarding chip).
@MainActor
final class LocalModelSelectionTests: XCTestCase {

    private var previousEngine: String?
    private var previousModel: String?

    override func setUp() async throws {
        try await super.setUp()
        let defaults = AppPreferences.defaults
        previousEngine = defaults.string(forKey: Constants.StorageKeys.transcriptionEngine)
        previousModel = defaults.string(forKey: Constants.StorageKeys.mlxWhisperModel)
        // Cloud engine so the ViewModel init never kicks off a local load.
        defaults.set(
            TranscriptionEngine.deepgram.rawValue,
            forKey: Constants.StorageKeys.transcriptionEngine
        )
    }

    override func tearDown() async throws {
        let defaults = AppPreferences.defaults
        restore(previousEngine, key: Constants.StorageKeys.transcriptionEngine, defaults: defaults)
        restore(previousModel, key: Constants.StorageKeys.mlxWhisperModel, defaults: defaults)
        try await super.tearDown()
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
        AppPreferences.defaults.set(model.rawValue, forKey: Constants.StorageKeys.mlxWhisperModel)
        let viewModel = SapoWhisperViewModel()
        try skipIfReallyDownloaded(model, in: viewModel)
        return viewModel
    }

    func testDeletingSelectedModelClearsSelection() throws {
        let viewModel = try makeViewModel(selecting: .largeV3Turbo)
        viewModel.mlxWhisperTranscriber.isLoading = true

        viewModel.deleteMLXWhisperModel(.largeV3Turbo)

        XCTAssertNil(viewModel.currentMLXWhisperModel)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isLoading)
    }

    func testNoModelStatusShowsLocalModelProgressWhileItLoads() throws {
        AppPreferences.defaults.set(TranscriptionEngine.mlxWhisper.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        let viewModel = try makeViewModel(selecting: .largeV3TurboQ8)
        try XCTSkipUnless(viewModel.appState == .noModel, "a backup engine is usable on this machine")
        let transcriber = viewModel.mlxWhisperTranscriber
        transcriber.loadingMessage = "mlx.state.downloading".localized(MLXWhisperModel.largeV3TurboQ8.displayName)

        transcriber.isLoading = true
        XCTAssertEqual(viewModel.statusText, transcriber.loadingMessage)

        transcriber.isLoading = false
        XCTAssertEqual(viewModel.statusText, "status.no_model".localized)
    }

    func testLocalModelBadgesRecommendEightBitAndMarkTurboAsMaxPrecision() {
        XCTAssertEqual(MLXWhisperModel.defaultModel, .largeV3TurboQ8)
        XCTAssertTrue(MLXWhisperModel.largeV3TurboQ8.isRecommended)
        XCTAssertFalse(MLXWhisperModel.largeV3Turbo.isRecommended)
        XCTAssertEqual(MLXWhisperModel.largeV3TurboQ8.badgeText, "model.tier_recommended".localized)
        XCTAssertEqual(MLXWhisperModel.largeV3Turbo.badgeText, "model.tier_max_precision".localized)
        XCTAssertEqual(MLXWhisperModel.largeV3TurboQ8.accuracy, 5)
        XCTAssertEqual(MLXWhisperModel.largeV3Turbo.accuracy, 5)
    }

    func testDeletingUnselectedModelKeepsSelection() throws {
        let viewModel = try makeViewModel(selecting: .largeV3Turbo)
        try skipIfReallyDownloaded(.largeV3TurboQ8, in: viewModel)

        viewModel.deleteMLXWhisperModel(.largeV3TurboQ8)

        XCTAssertEqual(viewModel.currentMLXWhisperModel, .largeV3Turbo)
    }

    func testSwitchingToLocalEngineDoesNotAutoDownload() throws {
        let viewModel = try makeViewModel(selecting: .largeV3Turbo)

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
        let viewModel = try makeViewModel(selecting: .largeV3Turbo)

        viewModel.deleteMLXWhisperModel(.largeV3Turbo)
        viewModel.setEngine(.deepgram)
        viewModel.setEngine(.mlxWhisper)

        XCTAssertNil(viewModel.currentMLXWhisperModel)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isAnyDownloadActive)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isLoading)
    }

    func testCloudEngineSelectionUnloadsMLXWhenAppStorageAlreadyChanged() {
        let viewModel = SapoWhisperViewModel()
        viewModel.mlxWhisperTranscriber.isModelLoaded = true
        viewModel.selectedEngine = TranscriptionEngine.localAIServer.rawValue

        viewModel.setEngine(.localAIServer)

        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isModelLoaded)
    }

    func testRapidLocalEngineRoundTripDoesNotStartLateMLXLoad() async throws {
        let model = MLXWhisperModel.largeV3Turbo
        let viewModel = try makeViewModel(selecting: model)
        viewModel.mlxWhisperTranscriber.downloadedModels.insert(model)
        defer {
            viewModel.mlxWhisperTranscriber.unloadModel()
            viewModel.mlxWhisperTranscriber.cancelDownload(model)
        }

        viewModel.setEngine(.mlxWhisper)
        viewModel.setEngine(.localAIServer)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isLoading)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isAnyDownloadActive)
        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isModelLoaded)
    }

    func testMLXCompletionAfterEngineSwitchUnloadsLateModel() {
        let viewModel = SapoWhisperViewModel()
        viewModel.setEngine(.localAIServer)
        viewModel.mlxWhisperTranscriber.isModelLoaded = true
        viewModel.mlxWhisperTranscriber.isTranscribing = true

        viewModel.mlxWhisperTranscriber.isTranscribing = false

        XCTAssertFalse(viewModel.mlxWhisperTranscriber.isModelLoaded)
    }
}
