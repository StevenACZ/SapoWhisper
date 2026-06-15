//
//  TranscriptionEngineSession.swift
//  SapoWhisper
//
//  Read-only activity state for the transcription engines, so the ViewModel
//  derives readiness/busy uniformly instead of duplicating a
//  `switch currentEngine` per query (deferred refactor, plan step 2).
//

import Foundation

/// Read-only activity state for one concrete transcriber.
///
/// A `TranscriptionEngine` is a *logical* engine (3 cases) that can be backed
/// by more than one concrete transcriber (e.g. Deepgram spans its batch and
/// Flux live sessions). Conforming each transcriber lets the ViewModel ask
/// "ready?" / "busy?" through one uniform surface instead of repeating the
/// per-engine `switch` at every call site.
@MainActor
protocol TranscriptionEngineSession: AnyObject {
    /// True when the session can begin a new dictation: the local model is
    /// loaded (WhisperKit) or the provider API key is present (cloud).
    var isReady: Bool { get }

    /// True while the session is mid-flight on any path — a live stream, a
    /// batch request, or a history reprocess — so a new recording must wait.
    var isBusy: Bool { get }
}

/// The concrete transcriber(s) backing one logical `TranscriptionEngine`.
///
/// `readiness` is the single source consulted for "engine available"; engine
/// readiness deliberately mirrors *that one* session and is never the AND/OR
/// of every backing transcriber (a cloud engine's batch and live sessions
/// share the same API key, and WhisperKit readiness is purely "model
/// loaded"). `busy` is OR-ed across every transcriber the engine can drive,
/// matching the historical guard that blocks a new recording while *any* of
/// the selected engine's sessions is in flight.
@MainActor
struct EngineSessions {
    /// The session whose `isReady` defines engine readiness.
    let readiness: TranscriptionEngineSession
    /// Every session whose `isBusy` blocks a new recording on this engine
    /// (includes `readiness`).
    let busy: [TranscriptionEngineSession]

    var isReady: Bool { readiness.isReady }

    var isBusy: Bool { busy.contains { $0.isBusy } }

    /// Whether a fresh recording may start. Mirrors the historical `canRecord`
    /// guard exactly: no active transcription session, the app is not already
    /// processing, the engine is ready, and nothing on the engine is in flight.
    func canRecord(hasActiveTranscriptionSession: Bool, appIsBusyProcessing: Bool) -> Bool {
        guard !hasActiveTranscriptionSession, !appIsBusyProcessing else { return false }
        return isReady && !isBusy
    }
}
