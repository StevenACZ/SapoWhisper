import XCTest

@testable import SapoWhisper

/// Pins the backup-engine failover: which variant takes a dictation, how long
/// a dead provider is remembered, and which failures a backup may rescue.
///
/// The behaviour used to live entirely inside the ViewModel's `@MainActor`
/// transcription path, where it could only be exercised against real engines.
/// Splitting the decision into plain values is what makes the "primary is
/// down, the user should not notice" contract testable at all.
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

    // MARK: - Reachability memory

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

    func testOnlyConnectivityClassFailuresAreRescued() {
        for kind in [TranscriptionFailure.Kind.network, .timedOut, .serverError] {
            XCTAssertTrue(
                EngineFailoverPolicy.isRescuable(TranscriptionFailure(kind: kind)),
                "\(kind.rawValue) must reach the backup"
            )
        }

        // A misconfigured engine, a cancelled take, or silence are not the
        // backup's problem — retrying them elsewhere burns credits and, for
        // empty transcriptions, would paste hallucinated text.
        let notRescued: [TranscriptionFailure.Kind] = [
            .notConfigured, .auth, .outOfCredits, .rateLimited, .planRestricted, .clientError,
            .audioEmpty, .audioCorrupt, .recordingInterrupted, .userCancelled, .emptyTranscription,
            .unknown,
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

    private let defaults = UserDefaults.standard
    private var restore: [String: String?] = [:]

    private func set(_ value: String, forKey key: String) {
        if restore[key] == nil {
            restore[key] = .some(defaults.string(forKey: key))
        }
        defaults.set(value, forKey: key)
    }

    override func tearDown() {
        for (key, previous) in restore {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        restore = [:]
        super.tearDown()
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
}
