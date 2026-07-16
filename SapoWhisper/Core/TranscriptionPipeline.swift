//
//  TranscriptionPipeline.swift
//  SapoWhisper
//

import Foundation
import os

/// Side effects the pipeline needs from its owner. The ViewModel satisfies
/// every requirement with helpers that already exist; tests drive the
/// pipeline with a spy host and assert the control flow.
@MainActor
protocol TranscriptionPipelineHost: AnyObject {
    /// True while the whole session peaked under the local silence threshold.
    var sessionLooksSilent: Bool { get }

    func isTranscriptionSessionCurrent(_ sessionID: UInt64) -> Bool
    func clearActiveTranscriptionSession()
    func handleStaleTranscriptionCompletion(audioURL: URL, sessionID: UInt64)

    func postProcessTranscript(_ rawText: String, source: String, duration: TimeInterval?) async -> TranscriptAIResult
    func deliverTranscription(_ aiResult: TranscriptAIResult, perf: DictationPerfTimeline?)
    func presentTranscriptionFailure(_ failure: TranscriptionFailure)

    func persistCompletedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?,
        target: HistoryPersistenceTarget
    )
    func persistFailedDictation(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        failure: TranscriptionFailure,
        target: HistoryPersistenceTarget
    )

    func logTranscriptionSnapshot(reason: String, extra: String)
}

/// Where the pipeline's result lands in History: live dictations insert a
/// fresh row; a retry refreshes the failed row it came from (and a failed
/// retry keeps that row untouched so it stays retryable). A dictation whose
/// audio was pre-persisted as a "transcribing" row finalizes that row in
/// place: success fills the transcript, failure marks it failed — either way
/// the audio is already safe in History before the engine ever runs.
enum HistoryPersistenceTarget: Equatable {
    case insertNew
    case updateExisting(historyId: Int64)
    case finalizePending(historyId: Int64)
}

/// C1: the transcribe→polish→paste→persist flow shared by the three stop
/// paths (batch recorder, Deepgram Flux, ElevenLabs realtime) plus retry.
/// The pipeline owns control flow only: stage order, the session-staleness
/// gate before every stage (C2), and the local-silence rule that skips
/// failed rows.
@MainActor
final class TranscriptionPipeline {
    struct Request {
        let sessionID: UInt64
        let engine: TranscriptionEngine
        /// Engine name persisted in history (mode-aware for streaming engines).
        let engineName: String
        /// Source tag for AI polish logs ("flux", "elevenlabs_realtime", …).
        let source: String
        /// Language persisted when the dictation fails before the engine
        /// reports a detected language.
        let failureLanguage: String
        /// Prefix for runtime snapshots ("flux-transcription", …).
        let snapshotPrefix: String
        let logger: Logger
        let perf: DictationPerfTimeline?
        var historyTarget: HistoryPersistenceTarget = .insertNew
    }

    struct EngineOutput {
        let transcript: String
        let audioURL: URL
        /// nil when the source duration is unknown (retry of a row without
        /// one) — the polish minimum-duration gate treats unknown as allowed.
        let duration: TimeInterval?
        /// Language persisted with the completed row (Flux reports the
        /// detected language; the other engines keep the selected one).
        let language: String
        /// Set when the transcript came from the configured backup engine
        /// instead of `request.engine`, so History records the engine that
        /// actually transcribed.
        var engineNameOverride: String? = nil
    }

    private unowned let host: TranscriptionPipelineHost

    init(host: TranscriptionPipelineHost) {
        self.host = host
    }

    func run(
        _ request: Request,
        transcribe: () async throws -> EngineOutput,
        captureResultOnFailure: () -> (audioURL: URL, duration: TimeInterval)?
    ) async {
        do {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let output = try await transcribe()
            request.perf?.markEngineDone()
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            request.logger.info(
                "Transcribe stage completed engine=\(request.engineName, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms characters=\(output.transcript.count, privacy: .public)"
            )
            host.logTranscriptionSnapshot(
                reason: "\(request.snapshotPrefix)-completed",
                extra:
                    "session=\(request.sessionID) engine=\(request.engine.rawValue) elapsedMs=\(elapsedMs) characters=\(output.transcript.count)"
            )
            guard ensureSessionCurrent(request, audioURL: output.audioURL) else { return }

            let aiResult = await host.postProcessTranscript(
                output.transcript,
                source: request.source,
                duration: output.duration
            )
            request.perf?.markPolishDone()
            guard ensureSessionCurrent(request, audioURL: output.audioURL) else { return }

            host.clearActiveTranscriptionSession()
            host.deliverTranscription(aiResult, perf: request.perf)
            host.persistCompletedDictation(
                audioURL: output.audioURL,
                engine: request.engine,
                engineName: output.engineNameOverride ?? request.engineName,
                language: output.language,
                duration: output.duration ?? 0,
                aiResult: aiResult,
                perf: request.perf,
                target: request.historyTarget
            )
        } catch {
            let captureResult = captureResultOnFailure()
            guard ensureSessionCurrent(request, audioURL: captureResult?.audioURL) else { return }

            let failure = TranscriptionFailure.from(error, engine: request.engine.displayName)
            host.clearActiveTranscriptionSession()
            host.logTranscriptionSnapshot(
                reason: "\(request.snapshotPrefix)-failed",
                extra: "session=\(request.sessionID) engine=\(request.engine.rawValue) failure=\(failure.diagnosticCode)"
            )
            host.presentTranscriptionFailure(failure)

            // Silence sessions keep their WAV but never create a failed
            // history row — there was nothing to transcribe. A pre-persisted
            // row is the exception: it already exists and must resolve, or it
            // would sit as "transcribing" until the next launch sweep.
            var hasPendingRow = false
            if case .finalizePending = request.historyTarget { hasPendingRow = true }
            let isLocalSilence = failure.kind == .emptyTranscription && host.sessionLooksSilent
            if let captureResult, !isLocalSilence || hasPendingRow {
                host.persistFailedDictation(
                    audioURL: captureResult.audioURL,
                    engine: request.engine,
                    engineName: request.engineName,
                    language: request.failureLanguage,
                    duration: captureResult.duration,
                    failure: failure,
                    target: request.historyTarget
                )
            }
            request.logger.error(
                "Transcription failed engine=\(request.engineName, privacy: .public) \(failure.logSummary, privacy: .public)"
            )
        }
    }

    /// C2: one staleness gate before every stage. A stale session cleans up
    /// its WAV (when known) and bows out without touching UI or history.
    private func ensureSessionCurrent(_ request: Request, audioURL: URL?) -> Bool {
        if host.isTranscriptionSessionCurrent(request.sessionID) {
            return true
        }
        if let audioURL {
            host.handleStaleTranscriptionCompletion(audioURL: audioURL, sessionID: request.sessionID)
        }
        return false
    }
}
