//
//  AudioCaptureCoordinator.swift
//  SapoWhisper
//

import Foundation
import os

/// A5: single owner of microphone exclusivity. Every capture path (batch
/// recorder, Flux streaming, ElevenLabs realtime) acquires the mic here before
/// starting, which guarantees the Settings level monitor is suspended first
/// and makes accidental concurrent captures loud instead of silent.
final class AudioCaptureCoordinator {

    static let shared = AudioCaptureCoordinator()

    enum CaptureOwner: String {
        case batchRecorder = "batch-recorder"
        case fluxStreaming = "flux-streaming"
        case elevenLabsStreaming = "elevenlabs-realtime"
    }

    private let lock = NSLock()
    private var activeOwner: CaptureOwner?
    private var shouldResumeMonitor = false

    private let suspendMonitor: () -> Bool
    private let resumeMonitor: () -> Void

    /// The default hooks talk to the shared `AudioLevelMonitor`; tests inject
    /// closures so the coordinator logic stays unit-testable.
    init(
        suspendMonitor: @escaping () -> Bool = { AudioLevelMonitor.shared.suspendForRecorder() },
        resumeMonitor: @escaping () -> Void = { AudioLevelMonitor.shared.resumeAfterRecorderIfNeeded() }
    ) {
        self.suspendMonitor = suspendMonitor
        self.resumeMonitor = resumeMonitor
    }

    /// True from `beginCapture` until the matching release. Used by the
    /// preflight manager (A8) to stay away from the device mid-capture.
    var isCaptureActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOwner != nil
    }

    var currentOwner: CaptureOwner? {
        lock.lock()
        defer { lock.unlock() }
        return activeOwner
    }

    /// Acquires the mic for a capture path. Suspends the level monitor when it
    /// was running. Overlapping captures are a state-machine bug upstream:
    /// they are logged, asserted in debug builds, and the new owner wins.
    func beginCapture(_ owner: CaptureOwner) {
        lock.lock()
        let previousOwner = activeOwner
        activeOwner = owner
        let alreadySuspended = shouldResumeMonitor
        lock.unlock()

        if let previousOwner, previousOwner != owner {
            SapoLog.recording.error(
                "Capture overlap detected active=\(previousOwner.rawValue, privacy: .public) incoming=\(owner.rawValue, privacy: .public)"
            )
            assertionFailure("Two captures overlapped: \(previousOwner.rawValue) → \(owner.rawValue)")
        }

        guard !alreadySuspended else { return }
        let didSuspend = suspendMonitor()
        if didSuspend {
            lock.lock()
            shouldResumeMonitor = true
            lock.unlock()
        }
    }

    /// Releases the mic when `owner` still holds it; stale releases from an
    /// older capture are ignored so a late cleanup cannot kill a new session.
    func endCapture(_ owner: CaptureOwner) {
        lock.lock()
        guard activeOwner == owner else {
            lock.unlock()
            return
        }
        activeOwner = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        lock.unlock()

        if resume {
            resumeMonitor()
        }
    }

    /// Releases whatever capture is active. For generic cleanup paths (sleep
    /// abort, error teardown) that do not know which engine was recording.
    func endActiveCapture() {
        lock.lock()
        activeOwner = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        lock.unlock()

        if resume {
            resumeMonitor()
        }
    }
}
