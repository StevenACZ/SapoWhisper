import Combine
import XCTest
import os

@testable import SapoWhisper

/// Pins the backup-engine failover: which variant takes a dictation, how long
/// a dead provider is remembered, and which failures a backup may rescue.
///
/// The behaviour used to live entirely inside the ViewModel's `@MainActor`
/// transcription path, where it could only be exercised against real engines.
/// Splitting the decision into plain values is what makes the "primary is
/// down, the user should not notice" contract testable at all.
@MainActor
final class EngineFailoverTests: XCTestCase {

    // MARK: - Variant mapping

    func testPrimaryResolvesEachEngineAndModeCombination() {
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .deepgram, deepgramMode: .nova3, elevenLabsMode: .scribeV2Batch),
            .deepgramNova3
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .deepgram, deepgramMode: .fluxLive, elevenLabsMode: .scribeV2Batch),
            .deepgramFluxLive
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .elevenLabsScribe, deepgramMode: .nova3, elevenLabsMode: .scribeV2Realtime),
            .elevenLabsScribeRealtime
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .elevenLabsScribe, deepgramMode: .fluxLive, elevenLabsMode: .scribeV2Batch),
            .elevenLabsScribeBatch,
            "the other brand's mode must not leak into the resolved variant"
        )
        // Local engines have no mode; neither picker may change them.
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .mlxWhisper, deepgramMode: .fluxLive, elevenLabsMode: .scribeV2Realtime),
            .mlxWhisper
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.primary(
                engine: .localAIServer, deepgramMode: .fluxLive, elevenLabsMode: .scribeV2Realtime),
            .localAIServer
        )
    }

    /// The backup picker used to store a plain engine. Those values must keep
    /// resolving to the file variant — the only thing the old picker ran — or
    /// an existing backup selection would silently become "None".
    func testStoredMigratesLegacyEngineSelections() {
        XCTAssertEqual(TranscriptionEngineVariant.stored("deepgram"), .deepgramNova3)
        XCTAssertEqual(TranscriptionEngineVariant.stored("elevenlabs_scribe"), .elevenLabsScribeBatch)
        XCTAssertEqual(TranscriptionEngineVariant.stored("mlx_whisper"), .mlxWhisper)
        XCTAssertEqual(TranscriptionEngineVariant.stored("local_ai_server"), .localAIServer)

        // New values round-trip untouched.
        for variant in TranscriptionEngineVariant.allCases {
            XCTAssertEqual(TranscriptionEngineVariant.stored(variant.rawValue), variant)
        }

        XCTAssertNil(TranscriptionEngineVariant.stored(""))
        XCTAssertNil(TranscriptionEngineVariant.stored("whisper"), "removed engines resolve to nothing")
    }

    func testLiveVariantsFallBackToTheirProviderFileModel() {
        XCTAssertEqual(TranscriptionEngineVariant.deepgramFluxLive.fileTranscriptionVariant, .deepgramNova3)
        XCTAssertEqual(
            TranscriptionEngineVariant.elevenLabsScribeRealtime.fileTranscriptionVariant,
            .elevenLabsScribeBatch
        )
        for variant in TranscriptionEngineVariant.allCases where !variant.isStreaming {
            XCTAssertEqual(variant.fileTranscriptionVariant, variant)
        }
    }

    /// The file-path rescue compares file variants, so a Flux Live primary and
    /// a Nova-3 backup must read as the same endpoint: retrying the upload
    /// that just failed is not a rescue. Different providers never collapse.
    func testAProvidersLiveAndFileVariantsShareOneFileEndpoint() {
        XCTAssertEqual(
            TranscriptionEngineVariant.deepgramFluxLive.fileTranscriptionVariant,
            TranscriptionEngineVariant.deepgramNova3.fileTranscriptionVariant
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.elevenLabsScribeRealtime.fileTranscriptionVariant,
            TranscriptionEngineVariant.elevenLabsScribeBatch.fileTranscriptionVariant
        )
        XCTAssertNotEqual(
            TranscriptionEngineVariant.deepgramNova3.fileTranscriptionVariant,
            TranscriptionEngineVariant.elevenLabsScribeBatch.fileTranscriptionVariant
        )
    }

    func testOnlyLiveVariantsAreStreaming() {
        XCTAssertEqual(
            Set(TranscriptionEngineVariant.allCases.filter(\.isStreaming)),
            [.deepgramFluxLive, .elevenLabsScribeRealtime]
        )
    }

    /// History rows and the backup picker must name an engine identically, or
    /// a rescued dictation reads as a different engine than the one chosen.
    func testDisplayNamesMatchTheHistoryLabels() {
        XCTAssertEqual(
            TranscriptionEngineVariant.deepgramFluxLive.displayName,
            DeepgramTranscriptionMode.fluxLive.historyName
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.elevenLabsScribeRealtime.displayName,
            ElevenLabsTranscriptionMode.scribeV2Realtime.historyName
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.deepgramNova3.displayName,
            DeepgramTranscriptionMode.nova3.historyName
        )
        XCTAssertEqual(
            TranscriptionEngineVariant.elevenLabsScribeBatch.displayName,
            ElevenLabsTranscriptionMode.scribeV2Batch.historyName
        )
    }

    func testModelOutputLimitCanUseTheConfiguredBackup() {
        let failure = TranscriptionFailure(kind: .modelOutputLimit, engine: "Local model")
        XCTAssertTrue(failure.isRetryable)
        XCTAssertTrue(EngineFailoverPolicy.isRescuable(failure))
        XCTAssertTrue(failure.localizedDescription.contains("Local model"))
        XCTAssertFalse(EngineFailoverPolicy.shouldRememberAsUnreachable(failure))
        for kind in [TranscriptionFailure.Kind.network, .timedOut, .serverError] {
            XCTAssertTrue(EngineFailoverPolicy.shouldRememberAsUnreachable(.init(kind: kind)))
        }
    }

    func testRejectedRequestsCanSwitchProvidersWithoutCachingBadConfiguration() {
        for status in [400, 401, 402, 403, 404, 413, 415, 422, 429] {
            let failure = TranscriptionFailure.fromHTTP(engine: "Primary", statusCode: status, body: Data())
            XCTAssertTrue(EngineFailoverPolicy.isRescuable(failure), "HTTP \(status)")
            XCTAssertTrue(EngineFailoverPolicy.isStartupRescuable(failure), "HTTP \(status)")
            XCTAssertFalse(EngineFailoverPolicy.shouldRememberAsUnreachable(failure), "HTTP \(status)")
        }
        for kind in [TranscriptionFailure.Kind.audioCorrupt, .recordingInterrupted, .userCancelled, .unknown] {
            XCTAssertFalse(EngineFailoverPolicy.isStartupRescuable(.init(kind: kind)))
        }
    }

    // MARK: - Reachability memory

    func testExplicitRetryBypassesRecentFailuresWithoutErasingNormalTakeProtection() {
        var log = EngineReachabilityLog()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for engine in [TranscriptionEngine.localAIServer, .deepgram] {
            log.markUnreachable(engine, at: now)
            XCTAssertTrue(log.isUnreachable(engine, at: now))
            XCTAssertFalse(log.isUnreachable(engine, at: now, ignoringRecentFailures: true))
            XCTAssertTrue(log.isUnreachable(engine, at: now))
        }
    }

    func testUnreachableEngineIsRememberedUntilTheTTLExpires() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var log = EngineReachabilityLog()
        XCTAssertFalse(log.isUnreachable(.localAIServer, at: start))

        log.markUnreachable(.localAIServer, at: start)
        XCTAssertTrue(log.isUnreachable(.localAIServer, at: start))
        XCTAssertTrue(
            log.isUnreachable(
                .localAIServer, at: start.addingTimeInterval(EngineReachabilityLog.unreachableTTL - 1))
        )
        // Past the TTL the engine is tried again on its own.
        XCTAssertFalse(
            log.isUnreachable(
                .localAIServer, at: start.addingTimeInterval(EngineReachabilityLog.unreachableTTL))
        )
    }

    func testSuccessClearsTheEntryImmediately() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var log = EngineReachabilityLog()
        log.markUnreachable(.deepgram, at: start)
        log.markReachable(.deepgram)
        XCTAssertFalse(log.isUnreachable(.deepgram, at: start))
    }

    func testOneDeadEngineDoesNotShadowTheOthers() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var log = EngineReachabilityLog()
        log.markUnreachable(.localAIServer, at: start)
        XCTAssertFalse(log.isUnreachable(.deepgram, at: start))
        XCTAssertFalse(log.isUnreachable(.mlxWhisper, at: start))
    }

    func testVerifiedRecoveryRestoresPrimaryBeforeCooldownExpires() {
        var log = EngineReachabilityLog()
        let now = Date()
        log.markUnreachable(.localAIServer, at: now)
        let check = log.beginObservation(for: .localAIServer)
        XCTAssertTrue(log.isUnreachable(.localAIServer, at: now))
        XCTAssertTrue(log.apply(check, reachable: true, at: now))
        let primary = EngineFailoverPolicy.Availability(
            isUsable: true, isKnownUnreachable: log.isUnreachable(.localAIServer, at: now))
        XCTAssertEqual(EngineFailoverPolicy.decision(primary: primary, backup: .healthy), .primary)
    }

    func testOldProbeCannotRestoreCooldownAfterConfigurationChanges() {
        var log = EngineReachabilityLog()
        let oldProbe = log.observation(for: .localAIServer)
        log.markReachable(.localAIServer)
        XCTAssertFalse(log.apply(oldProbe, reachable: false))
        XCTAssertFalse(log.isUnreachable(.localAIServer))
    }

    func testOldConnectionSuccessCannotEraseNewerTranscriptionFailure() {
        var log = EngineReachabilityLog()
        let check = log.beginObservation(for: .localAIServer)
        log.markUnreachable(.localAIServer)
        XCTAssertFalse(log.apply(check, reachable: true))
        XCTAssertTrue(log.isUnreachable(.localAIServer))
    }

    func testNewConnectionTestInvalidatesPriorProbeWithoutClearingCooldown() {
        var log = EngineReachabilityLog()
        log.markUnreachable(.localAIServer)
        let oldProbe = log.observation(for: .localAIServer)
        _ = log.beginObservation(for: .localAIServer)
        XCTAssertFalse(log.apply(oldProbe, reachable: true))
        XCTAssertTrue(log.isUnreachable(.localAIServer))
    }

    func testBackupSuccessDoesNotInvalidatePrimaryObservation() {
        var log = EngineReachabilityLog()
        let primaryProbe = log.observation(for: .localAIServer)
        log.markReachable(.deepgram)
        XCTAssertTrue(log.apply(primaryProbe, reachable: false))
        XCTAssertTrue(log.isUnreachable(.localAIServer))
        XCTAssertFalse(log.isUnreachable(.deepgram))
    }

    func testAnObservationCannotApplyTwice() {
        var log = EngineReachabilityLog()
        let check = log.beginObservation(for: .localAIServer)
        XCTAssertTrue(log.apply(check, reachable: true))
        XCTAssertFalse(log.apply(check, reachable: false))
        XCTAssertFalse(log.isUnreachable(.localAIServer))
    }

    // MARK: - Start decision

    func testHealthyPrimaryAlwaysKeepsTheDictation() {
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .healthy, backup: .healthy),
            .primary
        )
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .healthy, backup: nil),
            .primary
        )
    }

    func testUnconfiguredPrimaryHandsTheDictationToTheBackup() {
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .unusable, backup: .healthy),
            .backup(reason: .primaryNotReady)
        )
    }

    /// The case that must feel instant: the server is configured and fine on
    /// paper, but a probe already proved it down.
    func testKnownUnreachablePrimaryHandsTheDictationToTheBackup() {
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .unreachable, backup: .healthy),
            .backup(reason: .primaryUnreachable)
        )
    }

    func testUnreachablePrimaryIsStillAttemptedWithoutAUsableBackup() {
        // No backup at all...
        XCTAssertEqual(EngineFailoverPolicy.decision(primary: .unreachable, backup: nil), .primary)
        // ...and a backup that is itself down or unconfigured.
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .unreachable, backup: .unreachable), .primary)
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .unreachable, backup: .unusable), .primary)
    }

    func testNothingUsableBlocksRecording() {
        XCTAssertEqual(EngineFailoverPolicy.decision(primary: .unusable, backup: nil), .blocked)
        XCTAssertEqual(EngineFailoverPolicy.decision(primary: .unusable, backup: .unusable), .blocked)
        XCTAssertEqual(
            EngineFailoverPolicy.decision(primary: .unusable, backup: .unreachable), .blocked)
    }

    // MARK: - Rescuable failures

    func testProviderFailuresUseBackupWhileCaptureAndCancellationDoNot() {
        for kind in [
            TranscriptionFailure.Kind.network, .timedOut, .serverError, .notConfigured,
            .auth, .outOfCredits, .rateLimited, .planRestricted, .clientError, .modelOutputLimit, .unknown,
        ] {
            XCTAssertTrue(
                EngineFailoverPolicy.isRescuable(TranscriptionFailure(kind: kind)),
                "\(kind.rawValue) must reach the backup"
            )
        }

        let notRescued: [TranscriptionFailure.Kind] = [
            .audioEmpty, .audioCorrupt, .audioStorageFailed, .audioPreparationFailed,
            .recordingInterrupted, .userCancelled, .emptyTranscription,
        ]
        for kind in notRescued {
            XCTAssertFalse(
                EngineFailoverPolicy.isRescuable(TranscriptionFailure(kind: kind)),
                "\(kind.rawValue) must not reach the backup"
            )
        }
    }
}

/// The stored backup selection as the ViewModel reads it back.
@MainActor
final class BackupEngineSelectionTests: XCTestCase {

    private let defaults = AppPreferences.defaults
    private var restore: [String: String?] = [:]

    private func set(_ value: String, forKey key: String) {
        if restore[key] == nil {
            restore[key] = .some(defaults.string(forKey: key))
        }
        defaults.set(value, forKey: key)
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
        try await super.tearDown()
    }

    func testLegacyStoredBackupStillSelectsTheProviderFileVariant() {
        set(TranscriptionEngine.mlxWhisper.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set("deepgram", forKey: Constants.StorageKeys.fallbackTranscriptionEngine)

        XCTAssertEqual(SapoWhisperViewModel().fallbackVariant, .deepgramNova3)
    }

    /// A backup on the primary's own provider reads as "no backup" — including
    /// the sibling live mode. Readiness and reachability are provider-wide (one
    /// key, one host), so a sibling is down exactly when the primary is and
    /// could never rescue anything; offering it would promise a rescue that can
    /// never run.
    func testBackupOnThePrimaryProviderReadsAsNoBackup() {
        set(TranscriptionEngine.deepgram.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set(DeepgramTranscriptionMode.nova3.rawValue, forKey: Constants.StorageKeys.deepgramTranscriptionMode)

        for sibling: TranscriptionEngineVariant in [.deepgramNova3, .deepgramFluxLive] {
            set(sibling.rawValue, forKey: Constants.StorageKeys.fallbackTranscriptionEngine)
            XCTAssertNil(
                SapoWhisperViewModel().fallbackVariant,
                "\(sibling.rawValue) shares Deepgram's key and host — it cannot be its own backup"
            )
        }

        // A different provider is a real backup, live mode included.
        set(
            TranscriptionEngineVariant.elevenLabsScribeRealtime.rawValue,
            forKey: Constants.StorageKeys.fallbackTranscriptionEngine
        )
        XCTAssertEqual(SapoWhisperViewModel().fallbackVariant, .elevenLabsScribeRealtime)
    }

    /// The legacy migration must not resurrect a same-provider backup: before
    /// the picker listed modes, "deepgram" stored against a Deepgram primary
    /// meant "none", and it still has to.
    func testLegacyValueOnThePrimaryProviderStaysNoBackup() {
        set(TranscriptionEngine.deepgram.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set(DeepgramTranscriptionMode.fluxLive.rawValue, forKey: Constants.StorageKeys.deepgramTranscriptionMode)
        set("deepgram", forKey: Constants.StorageKeys.fallbackTranscriptionEngine)

        XCTAssertNil(SapoWhisperViewModel().fallbackVariant)
    }

    func testPrimaryVariantFollowsTheModePicker() {
        set(TranscriptionEngine.deepgram.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set(
            DeepgramTranscriptionMode.fluxLive.rawValue,
            forKey: Constants.StorageKeys.deepgramTranscriptionMode
        )
        XCTAssertEqual(SapoWhisperViewModel().currentVariant, .deepgramFluxLive)
    }
    private func configuredLocalServerViewModel(baseURL: String = "http://127.0.0.1:9876") -> SapoWhisperViewModel {
        set(TranscriptionEngine.localAIServer.rawValue, forKey: Constants.StorageKeys.transcriptionEngine)
        set(baseURL, forKey: Constants.StorageKeys.localAIServerBaseURL)
        set("test-model", forKey: Constants.StorageKeys.localAIServerModel)
        return SapoWhisperViewModel()
    }

    private final class ProbeProvider: URLProtocol {
        nonisolated static let host = "connection-probe-race-fixture.invalid"
        nonisolated static let onRequest = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.onRequest.withLock { $0 }?()
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func proveBackgroundProbeCanComplete(in viewModel: SapoWhisperViewModel) async {
        let requested = expectation(description: "Fixture received background health request")
        let published = expectation(description: "Background health result was applied")
        ProbeProvider.onRequest.withLock { $0 = { requested.fulfill() } }
        let subscription = viewModel.$localAIServerConnectionState
            .first { $0 == .reachable }
            .sink { _ in published.fulfill() }
        viewModel.startReachabilityProbe(for: .localAIServer)
        await fulfillment(of: [requested, published], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(viewModel.localAIServerConnectionState, .reachable)
    }

    private func attemptBackgroundProbeDuringManualCheck(in viewModel: SapoWhisperViewModel) async {
        let unexpected = expectation(description: "Manual check owns the provider observation")
        unexpected.isInverted = true
        ProbeProvider.onRequest.withLock { $0 = { unexpected.fulfill() } }
        viewModel.startReachabilityProbe(for: .localAIServer)
        await fulfillment(of: [unexpected], timeout: 0.25)
        ProbeProvider.onRequest.withLock { $0 = nil }
        XCTAssertEqual(viewModel.localAIServerConnectionState, .checking)
    }

    func testPendingManualConnectionSuccessKeepsAuthorityOverBackgroundProbeAndClearsCooldown() async throws {
        try XCTSkipUnless(AppRuntimePaths.isIsolated, "Requires isolated test preferences")
        XCTAssertTrue(URLProtocol.registerClass(ProbeProvider.self))
        defer {
            ProbeProvider.onRequest.withLock { $0 = nil }
            URLProtocol.unregisterClass(ProbeProvider.self)
        }
        let viewModel = configuredLocalServerViewModel(baseURL: "https://\(ProbeProvider.host)")
        await proveBackgroundProbeCanComplete(in: viewModel)
        let initialFailure = viewModel.beginLocalAIServerConnectionTest()
        viewModel.failLocalAIServerConnectionTest(initialFailure, error: URLError(.timedOut))
        XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))

        let manualCheck = viewModel.beginLocalAIServerConnectionTest()
        await attemptBackgroundProbeDuringManualCheck(in: viewModel)
        XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))
        XCTAssertTrue(viewModel.completeLocalAIServerConnectionTest(manualCheck, modelAvailable: true))
        XCTAssertEqual(viewModel.localAIServerConnectionState, .verified(modelAvailable: true))
        XCTAssertTrue(viewModel.isBackupEngineUsable(.localAIServer))
    }

    func testPendingManualConnectionFailureKeepsAuthorityAndItsCooldownPolicy() async throws {
        try XCTSkipUnless(AppRuntimePaths.isIsolated, "Requires isolated test preferences")
        XCTAssertTrue(URLProtocol.registerClass(ProbeProvider.self))
        defer {
            ProbeProvider.onRequest.withLock { $0 = nil }
            URLProtocol.unregisterClass(ProbeProvider.self)
        }
        for statusCode in [503, 401] {
            let viewModel = configuredLocalServerViewModel(baseURL: "https://\(ProbeProvider.host)")
            await proveBackgroundProbeCanComplete(in: viewModel)
            let initialFailure = viewModel.beginLocalAIServerConnectionTest()
            viewModel.failLocalAIServerConnectionTest(initialFailure, error: URLError(.timedOut))
            XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))

            let manualCheck = viewModel.beginLocalAIServerConnectionTest()
            await attemptBackgroundProbeDuringManualCheck(in: viewModel)
            XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))
            viewModel.failLocalAIServerConnectionTest(
                manualCheck, error: LocalAIServerConnectionError.server(statusCode: statusCode, body: ""))
            guard case .failed = viewModel.localAIServerConnectionState else {
                XCTFail("Manual failure must publish even when a background probe was requested")
                continue
            }
            XCTAssertEqual(viewModel.isBackupEngineUsable(.localAIServer), statusCode == 401)
        }
    }

    func testConnectionRecoveryUpdatesStatusAndRoutingTogether() {
        let viewModel = configuredLocalServerViewModel()
        let failedCheck = viewModel.beginLocalAIServerConnectionTest()
        viewModel.failLocalAIServerConnectionTest(failedCheck, error: URLError(.cannotConnectToHost))
        guard case .failed = viewModel.localAIServerConnectionState else { return XCTFail("Expected failed status") }
        XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))
        XCTAssertTrue(viewModel.isBackupEngineConfigured(.localAIServer))

        let recoveredCheck = viewModel.beginLocalAIServerConnectionTest()
        XCTAssertEqual(viewModel.localAIServerConnectionState, .checking)
        XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))
        XCTAssertTrue(viewModel.completeLocalAIServerConnectionTest(recoveredCheck, modelAvailable: true))
        XCTAssertEqual(viewModel.localAIServerConnectionState, .verified(modelAvailable: true))
        XCTAssertTrue(viewModel.isBackupEngineUsable(.localAIServer))
    }

    func testConfigurationChangeDiscardsOldConnectionResultAndCooldown() {
        let viewModel = configuredLocalServerViewModel()
        let failedCheck = viewModel.beginLocalAIServerConnectionTest()
        viewModel.failLocalAIServerConnectionTest(failedCheck, error: URLError(.timedOut))
        let oldCheck = viewModel.beginLocalAIServerConnectionTest()
        set("http://127.0.0.1:9877", forKey: Constants.StorageKeys.localAIServerBaseURL)
        viewModel.setEngine(.localAIServer)
        viewModel.failLocalAIServerConnectionTest(oldCheck, error: URLError(.cannotConnectToHost))
        XCTAssertFalse(viewModel.completeLocalAIServerConnectionTest(oldCheck, modelAvailable: true))
        XCTAssertEqual(viewModel.localAIServerConnectionState, .unchecked)
        XCTAssertTrue(viewModel.isBackupEngineUsable(.localAIServer))
    }

    func testCancelledOrReplacedConnectionChecksCannotPublishLateResults() {
        let viewModel = configuredLocalServerViewModel()
        let initial = viewModel.beginLocalAIServerConnectionTest()
        XCTAssertTrue(viewModel.completeLocalAIServerConnectionTest(initial, modelAvailable: false))
        let oldCheck = viewModel.beginLocalAIServerConnectionTest()
        let newCheck = viewModel.beginLocalAIServerConnectionTest()
        viewModel.cancelLocalAIServerConnectionTest(oldCheck)
        XCTAssertFalse(viewModel.completeLocalAIServerConnectionTest(oldCheck, modelAvailable: true))
        XCTAssertEqual(viewModel.localAIServerConnectionState, .checking)
        viewModel.cancelLocalAIServerConnectionTest(newCheck)
        XCTAssertEqual(viewModel.localAIServerConnectionState, .verified(modelAvailable: false))
        XCTAssertFalse(viewModel.completeLocalAIServerConnectionTest(newCheck, modelAvailable: true))
    }

    func testConnectionHTTPFailuresFollowProviderCooldownPolicy() {
        let viewModel = configuredLocalServerViewModel()
        for statusCode in [503, 401] {
            let check = viewModel.beginLocalAIServerConnectionTest()
            viewModel.failLocalAIServerConnectionTest(
                check, error: LocalAIServerConnectionError.server(statusCode: statusCode, body: ""))
            guard case .failed = viewModel.localAIServerConnectionState else { return XCTFail("Expected failed status") }
            XCTAssertEqual(viewModel.isBackupEngineUsable(.localAIServer), statusCode == 401)
        }
    }

    func testOldServerTranscriptionCannotChangeNewServerStatusOrRouting() {
        let viewModel = configuredLocalServerViewModel()
        let oldRevision = viewModel.localAIServerConfigurationRevision
        set("http://127.0.0.1:9877", forKey: Constants.StorageKeys.localAIServerBaseURL)
        viewModel.setEngine(.localAIServer)
        let check = viewModel.beginLocalAIServerConnectionTest()
        XCTAssertTrue(viewModel.completeLocalAIServerConnectionTest(check, modelAvailable: true))
        for failure: TranscriptionFailure? in [.init(kind: .network), nil] {
            viewModel.recordTranscriptionOutcome(.localAIServer, configurationRevision: oldRevision, failure: failure)
            XCTAssertEqual(viewModel.localAIServerConnectionState, .verified(modelAvailable: true))
            XCTAssertTrue(viewModel.isBackupEngineUsable(.localAIServer))
        }
    }

    func testCurrentServerTranscriptionOutranksConnectionChecks() {
        let viewModel = configuredLocalServerViewModel()
        let revision = viewModel.localAIServerConfigurationRevision
        let check = viewModel.beginLocalAIServerConnectionTest()
        viewModel.recordTranscriptionOutcome(
            .localAIServer, configurationRevision: revision, failure: .init(kind: .network))
        XCTAssertFalse(viewModel.completeLocalAIServerConnectionTest(check, modelAvailable: true))
        XCTAssertFalse(viewModel.isBackupEngineUsable(.localAIServer))
        viewModel.recordTranscriptionOutcome(.localAIServer, configurationRevision: revision)
        XCTAssertEqual(viewModel.localAIServerConnectionState, .transcribed)
        XCTAssertTrue(viewModel.isBackupEngineUsable(.localAIServer))
    }

}
