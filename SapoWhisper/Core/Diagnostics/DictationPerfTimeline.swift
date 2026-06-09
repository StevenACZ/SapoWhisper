//
//  DictationPerfTimeline.swift
//  SapoWhisper
//

import Foundation
import os

/// Collects per-stage timings for one successful dictation and emits a single
/// `Performance` log line once paste and persist have both reported:
/// `perf stop→paste totalMs=… stages={tail:…,finalize:…,engine:…,polish:…,paste:…,persist:…}`
/// `totalMs` is stop-request → paste posted; persistence runs off that path.
/// Streaming engines fold local finalize into their stop call, so they report
/// `finalize:0` and the detail lives in the engine's own stop logs.
@MainActor
final class DictationPerfTimeline {
    private let engine: String
    private let stopRequestedAt: CFAbsoluteTime
    private var lastMarkAt: CFAbsoluteTime
    private var tailMs = 0
    private var finalizeMs = 0
    private var engineMs = 0
    private var polishMs = 0
    private var pasteMs: Int?
    private var persistMs: Int?
    private var totalToPasteMs: Int?
    private var didLog = false

    init(engine: String) {
        self.engine = engine
        self.stopRequestedAt = CFAbsoluteTimeGetCurrent()
        self.lastMarkAt = stopRequestedAt
    }

    private func elapsedSinceLastMark() -> Int {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = Int((now - lastMarkAt) * 1000)
        lastMarkAt = now
        return max(0, elapsed)
    }

    func markTailDone() { tailMs = elapsedSinceLastMark() }
    func markFinalizeDone() { finalizeMs = elapsedSinceLastMark() }
    func markEngineDone() { engineMs = elapsedSinceLastMark() }
    func markPolishDone() { polishMs = elapsedSinceLastMark() }

    /// Paste was posted (or clipboard set, when auto-paste is off).
    func markPasteDone(skipped: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        pasteMs = skipped ? 0 : max(0, Int((now - lastMarkAt) * 1000))
        totalToPasteMs = Int((now - stopRequestedAt) * 1000)
        logIfComplete()
    }

    /// Persistence finished off the paste path (0 when it was skipped).
    nonisolated func reportPersist(elapsedMs: Int) {
        Task { @MainActor in
            self.persistMs = max(0, elapsedMs)
            self.logIfComplete()
        }
    }

    private func logIfComplete() {
        guard !didLog, let pasteMs, let persistMs, let totalToPasteMs else { return }
        didLog = true
        SapoLog.performance.info(
            "perf stop→paste engine=\(self.engine, privacy: .public) totalMs=\(totalToPasteMs, privacy: .public) stages={tail:\(self.tailMs, privacy: .public),finalize:\(self.finalizeMs, privacy: .public),engine:\(self.engineMs, privacy: .public),polish:\(self.polishMs, privacy: .public),paste:\(pasteMs, privacy: .public),persist:\(persistMs, privacy: .public)}"
        )
    }
}
