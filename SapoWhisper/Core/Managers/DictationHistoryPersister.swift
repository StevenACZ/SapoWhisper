//
//  DictationHistoryPersister.swift
//  SapoWhisper
//

import Foundation
import os

/// History persistence for live dictations: completed/failed/aborted rows,
/// the failed-retry pointers, and the generation gate that keeps a stale
/// background persist from clobbering a newer dictation's row pointer.
@MainActor
final class DictationHistoryPersister {

    private struct PersistedEntry {
        let id: Int64
        let audioURL: URL?
        let copiedAudioToHistory: Bool
    }

    /// Result of persisting an aborted capture: the failed row (when the
    /// insert succeeded) and the audio the retry/resume offers point at.
    struct AbortOutcome {
        let historyId: Int64?
        /// History copy (or source fallback); nil when no WAV survived.
        let audioURL: URL?
        let preservedAudio: Bool
    }

    // Retry support
    private(set) var lastFailedAudioURL: URL?
    private(set) var lastFailedHistoryId: Int64?

    /// History row of the last completed dictation (arrives async from the
    /// background persistence task); lets a re-polish update the row in place.
    private(set) var lastCompletedHistoryId: Int64?
    /// Invalidates a stale persistence callback racing a newer dictation.
    private(set) var dictationGeneration: UInt64 = 0

    private let historyManager: TranscriptionHistoryManager
    private let deleteSourceAudio: @Sendable (URL) -> Void

    init(
        historyManager: TranscriptionHistoryManager = .shared,
        deleteSourceAudio: @escaping @Sendable (URL) -> Void
    ) {
        self.historyManager = historyManager
        self.deleteSourceAudio = deleteSourceAudio
    }

    /// A new dictation is being delivered: bump the generation so stale
    /// persistence callbacks are ignored, and drop the previous row pointer.
    func beginNewDictationDelivery() {
        dictationGeneration &+= 1
        lastCompletedHistoryId = nil
    }

    func persistCompleted(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?,
        target: HistoryPersistenceTarget
    ) {
        switch target {
        case .insertNew:
            scheduleCompletedPersistence(
                from: audioURL,
                engine: engine,
                engineName: engineName,
                language: language,
                duration: duration,
                aiResult: aiResult,
                perf: perf
            )
        case .updateExisting(let historyId), .finalizePending(let historyId):
            // Retry path and pre-persisted pending rows: refresh the row in
            // place (the transcript may have come from a different engine
            // than the one recorded at insert time).
            historyManager.updateRetranscription(
                id: historyId,
                engine: engineName,
                finalText: aiResult.finalText,
                rawText: aiResult.rawText,
                aiStatus: aiResult.status,
                aiModel: aiResult.model,
                aiMode: aiResult.mode,
                aiError: aiResult.error
            )
            lastCompletedHistoryId = historyId
        }
        lastFailedAudioURL = nil
        lastFailedHistoryId = nil
    }

    func persistFailed(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String,
        language: String,
        duration: TimeInterval,
        failure: TranscriptionFailure,
        target: HistoryPersistenceTarget
    ) {
        if case .updateExisting = target {
            // A failed retry keeps the original failed row (and the retry
            // state) untouched so the user can retry again.
            SapoLog.recording.info("Retry failed; keeping original failed history row")
            return
        }
        if case .finalizePending(let historyId) = target {
            // The audio already lives in History; only the row status needs
            // to resolve so the dictation shows up as failed + retryable.
            historyManager.markTranscriptionFailed(
                id: historyId, failureCode: failure.diagnosticCode)
            lastFailedHistoryId = historyId
            lastFailedAudioURL = audioURL
            return
        }
        let persistedEntry = persistEntry(
            from: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: nil,
            status: "failed",
            failureCode: failure.diagnosticCode
        )
        lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
        lastFailedAudioURL = persistedEntry.audioURL ?? audioURL
        cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
    }

    /// Result of pre-persisting a dictation before its engine runs: the
    /// pending row and the History copy of the WAV the engine should read.
    struct PendingOutcome {
        let historyId: Int64
        let audioURL: URL
    }

    /// Persists the finished capture into History as a "transcribing" row
    /// BEFORE the engine runs, so a hang, crash, cancel, or force-quit during
    /// transcription can never lose the audio. The pipeline then finalizes
    /// the row via `.finalizePending`. Returns nil when the insert or the
    /// audio copy failed — callers fall back to the legacy post-persist flow.
    func persistPending(
        audioURL: URL,
        engine: TranscriptionEngine,
        engineName: String?,
        language: String,
        duration: TimeInterval
    ) -> PendingOutcome? {
        let persistedEntry = persistEntry(
            from: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: nil,
            status: "transcribing"
        )
        // Insert failure already rolled back the copied audio inside the
        // manager; a rowless pending state falls back to the legacy flow.
        // A copy failure with a good row is still usable: the row references
        // the temp WAV, exactly like failed rows do when the copy fails.
        guard persistedEntry.id > 0, let pendingAudioURL = persistedEntry.audioURL else {
            SapoLog.recording.warning("Pre-transcription persist unavailable; using legacy flow")
            return nil
        }
        cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
        return PendingOutcome(historyId: persistedEntry.id, audioURL: pendingAudioURL)
    }

    /// Persistence half of the abort paths (sleep, device failure, cancel,
    /// quit): the WAV recorded so far becomes a failed history row, and the
    /// retry pointers arm only when the caller wants Retry available.
    func persistAbortedCapture(
        audioURL: URL,
        duration: TimeInterval,
        engine: TranscriptionEngine,
        engineName: String?,
        language: String,
        failureKind: TranscriptionFailure.Kind,
        storeRetryState: Bool
    ) -> AbortOutcome {
        let persistedEntry = persistEntry(
            from: audioURL,
            engine: engine,
            engineName: engineName,
            language: language,
            duration: duration,
            aiResult: nil,
            status: "failed",
            failureCode: TranscriptionFailure(
                kind: failureKind, engine: engine.displayName
            ).diagnosticCode
        )
        if storeRetryState {
            lastFailedHistoryId = persistedEntry.id > 0 ? persistedEntry.id : nil
            lastFailedAudioURL = persistedEntry.audioURL ?? audioURL
        } else {
            clearRetryState()
        }
        cleanupSourceAudioIfSafe(sourceURL: audioURL, persistedEntry: persistedEntry)
        return AbortOutcome(
            historyId: persistedEntry.id > 0 ? persistedEntry.id : nil,
            audioURL: persistedEntry.audioURL ?? audioURL,
            preservedAudio: persistedEntry.audioURL != nil
        )
    }

    /// Drops any pending failed-retry state. Called when a session ends without
    /// persisting a retryable failure (empty / interrupted / offline fast-fail),
    /// so a later Retry cannot retranscribe and paste a STALE prior session's
    /// audio (the interrupted/offline paths leave no valid audio to retry).
    func clearRetryState() {
        lastFailedAudioURL = nil
        lastFailedHistoryId = nil
    }

    /// Cleanup for a stale transcription completion's WAV. A retry transcribes
    /// the failed row's HISTORY audio — going stale must never delete a file
    /// the History still references.
    func cleanUpStaleAudio(_ audioURL: URL) {
        guard audioURL != lastFailedAudioURL else { return }
        // Pre-persisted dictations hand the pipeline a History-owned WAV —
        // going stale (e.g. a cancelled transcription) must never delete it.
        guard !historyManager.ownsAudioFile(at: audioURL) else { return }
        // Directory ownership is not enough: when the History copy fails, the
        // row keeps pointing at the TEMP WAV, which is the only audio left.
        guard let referencedPaths = historyManager.referencedAudioPathsIfComplete() else {
            SapoLog.recording.error("failure=History/staleAudioCleanup detail=incomplete-reference-scan")
            return
        }
        let referencedNames = Set(referencedPaths.map { ($0 as NSString).lastPathComponent })
        guard !referencedNames.contains(audioURL.lastPathComponent) else { return }
        deleteSourceAudio(audioURL)
    }

    /// L3: completed dictations persist off the paste path. The audio copy and
    /// the SQLite insert run on a background task; the UI is already idle.
    /// Failed dictations keep the synchronous path because the retry UI needs
    /// the persisted row id immediately.
    private func scheduleCompletedPersistence(
        from sourceURL: URL,
        engine: TranscriptionEngine,
        engineName: String?,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult,
        perf: DictationPerfTimeline?
    ) {
        let generation = dictationGeneration
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            let persistedEntry = self.persistEntry(
                from: sourceURL,
                engine: engine,
                engineName: engineName,
                language: language,
                duration: duration,
                aiResult: aiResult,
                status: "completed"
            )
            self.cleanupSourceAudioIfSafe(sourceURL: sourceURL, persistedEntry: persistedEntry)
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            SapoLog.performance.info("History persisted off paste path elapsed=\(elapsedMs, privacy: .public)ms")
            perf?.reportPersist(elapsedMs: elapsedMs)

            // Hand the row id back so an overlay re-polish can update it —
            // only if a newer dictation has not replaced this one.
            let rowID = persistedEntry.id
            guard rowID > 0 else { return }
            await MainActor.run {
                guard self.dictationGeneration == generation else { return }
                self.lastCompletedHistoryId = rowID
            }
        }
    }

    nonisolated private func persistEntry(
        from sourceURL: URL,
        engine: TranscriptionEngine,
        engineName: String? = nil,
        language: String,
        duration: TimeInterval,
        aiResult: TranscriptAIResult?,
        status: String,
        failureCode: String? = nil
    ) -> PersistedEntry {
        // Persist atomically through the manager: it copies the WAV and inserts
        // the row under `persistenceLock` so a concurrent save's orphan sweep
        // cannot delete the freshly copied audio before its row references it.
        let text = aiResult?.finalText ?? ""
        let result = historyManager.persistEntry(
            audioSource: sourceURL,
            engine: engineName ?? engine.displayName,
            language: language,
            duration: duration,
            text: text,
            rawText: aiResult?.rawText ?? text,
            status: status,
            aiStatus: aiResult?.status.rawValue ?? TranscriptAIStatus.none.rawValue,
            aiModel: aiResult?.model,
            aiMode: aiResult?.mode,
            aiError: aiResult?.error,
            failureCode: failureCode
        )

        return PersistedEntry(
            id: result.rowID,
            audioURL: result.audioPath.map { URL(fileURLWithPath: $0) },
            copiedAudioToHistory: result.copiedToHistory
        )
    }

    nonisolated private func cleanupSourceAudioIfSafe(sourceURL: URL, persistedEntry: PersistedEntry) {
        guard persistedEntry.copiedAudioToHistory else {
            SapoLog.recording.warning(
                "Keeping source audio because history copy was unavailable path=\(sourceURL.path, privacy: .private)"
            )
            return
        }

        deleteSourceAudio(sourceURL)
    }
}
