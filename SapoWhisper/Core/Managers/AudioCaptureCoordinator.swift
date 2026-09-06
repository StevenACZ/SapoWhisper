//
//  AudioCaptureCoordinator.swift
//  SapoWhisper
//

import Foundation
import os

nonisolated final class AudioInputActivityGate: @unchecked Sendable {
    struct CaptureLease: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    static let shared = AudioInputActivityGate()

    private let lock = NSLock()
    private var nextCaptureLeaseID: UInt64 = 0
    private var activeCaptureLeaseID: UInt64?
    private var preflightActive = false
    private var monitorActive = false
    private let captureWaitTimeout: Duration

    init(captureWaitTimeout: Duration = .seconds(5)) {
        self.captureWaitTimeout = captureWaitTimeout
    }

    func beginCapture() async throws -> CaptureLease {
        let lease = lock.withLock {
            nextCaptureLeaseID &+= 1
            let lease = CaptureLease(id: nextCaptureLeaseID)
            activeCaptureLeaseID = lease.id
            return lease
        }
        let deadline = ContinuousClock.now.advanced(by: captureWaitTimeout)
        do {
            while lock.withLock({ preflightActive }) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw RecordingError.inputSetupTimedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            return lease
        } catch {
            endCapture(lease)
            throw error
        }
    }

    func endCapture(_ lease: CaptureLease) {
        lock.lock()
        guard activeCaptureLeaseID == lease.id else {
            lock.unlock()
            return
        }
        activeCaptureLeaseID = nil
        lock.unlock()
    }

    func beginPreflightIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeCaptureLeaseID == nil, !preflightActive, !monitorActive else { return false }
        preflightActive = true
        return true
    }

    func endPreflight() {
        lock.lock()
        preflightActive = false
        lock.unlock()
    }

    func beginMonitorIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeCaptureLeaseID == nil, !preflightActive, !monitorActive else { return false }
        monitorActive = true
        return true
    }

    func endMonitor() {
        lock.lock()
        monitorActive = false
        lock.unlock()
    }
}

/// A5: single owner of microphone exclusivity. Every capture path (batch
/// recorder, Flux streaming, ElevenLabs realtime) acquires the mic here before
/// starting, which guarantees the Settings level monitor is suspended first
/// and makes accidental concurrent captures loud instead of silent.
@MainActor
final class AudioCaptureCoordinator {

    static let shared = AudioCaptureCoordinator()

    enum CaptureOwner: String {
        case batchRecorder = "batch-recorder"
        case fluxStreaming = "flux-streaming"
        case elevenLabsStreaming = "elevenlabs-realtime"
    }

    struct CaptureToken: Equatable {
        let owner: CaptureOwner
        fileprivate let lease: AudioInputActivityGate.CaptureLease
    }

    private var activeToken: CaptureToken?
    private var shouldResumeMonitor = false

    private let suspendMonitor: () -> Bool
    private let resumeMonitor: () -> Void
    private let activityGate: AudioInputActivityGate

    /// The default hooks talk to the shared `AudioLevelMonitor`; tests inject
    /// closures so the coordinator logic stays unit-testable.
    init(
        suspendMonitor: @escaping () -> Bool = { AudioLevelMonitor.shared.suspendForRecorder() },
        resumeMonitor: @escaping () -> Void = { AudioLevelMonitor.shared.resumeAfterRecorderIfNeeded() },
        activityGate: AudioInputActivityGate = .shared
    ) {
        self.suspendMonitor = suspendMonitor
        self.resumeMonitor = resumeMonitor
        self.activityGate = activityGate
    }

    /// True from `beginCapture` until the matching release. Used by the
    /// preflight manager (A8) to stay away from the device mid-capture.
    var isCaptureActive: Bool {
        return activeToken != nil
    }

    var currentOwner: CaptureOwner? {
        return activeToken?.owner
    }

    /// Acquires the mic for a capture path. Suspends the level monitor when it
    /// was running. Overlapping captures are a state-machine bug upstream:
    /// they are logged, asserted in debug builds, and the new owner wins.
    func beginCapture(_ owner: CaptureOwner) async throws -> CaptureToken? {
        let lease = try await activityGate.beginCapture()
        guard !Task.isCancelled else {
            activityGate.endCapture(lease)
            return nil
        }
        let token = CaptureToken(owner: owner, lease: lease)
        let previousOwner = activeToken?.owner
        activeToken = token
        let alreadySuspended = shouldResumeMonitor

        if let previousOwner, previousOwner != owner {
            SapoLog.recording.error(
                "Capture overlap detected active=\(previousOwner.rawValue, privacy: .public) incoming=\(owner.rawValue, privacy: .public)"
            )
            assertionFailure("Two captures overlapped: \(previousOwner.rawValue) → \(owner.rawValue)")
        }

        guard !alreadySuspended else { return token }
        let didSuspend = suspendMonitor()
        if didSuspend {
            shouldResumeMonitor = true
        }
        return token
    }

    /// Releases the mic when `token` still holds it; stale releases from an
    /// older capture are ignored so a late cleanup cannot kill a new session.
    func endCapture(_ token: CaptureToken) {
        guard activeToken == token else {
            return
        }
        activeToken = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        activityGate.endCapture(token.lease)

        if resume {
            resumeMonitor()
        }
    }

    /// Releases whatever capture is active. For generic cleanup paths (sleep
    /// abort, error teardown) that do not know which engine was recording.
    func endActiveCapture() {
        let token = activeToken
        activeToken = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        if let token {
            activityGate.endCapture(token.lease)
        }

        if resume {
            resumeMonitor()
        }
    }
}
