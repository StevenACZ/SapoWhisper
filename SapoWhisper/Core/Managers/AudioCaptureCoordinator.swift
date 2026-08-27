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

    private let condition = NSCondition()
    private let waitQueue = DispatchQueue(label: "com.sapowhisper.audioInput.activity", qos: .userInitiated)
    private var nextCaptureLeaseID: UInt64 = 0
    private var activeCaptureLeaseID: UInt64?
    private var preflightActive = false
    private var monitorActive = false

    func beginCapture() async -> CaptureLease {
        await withCheckedContinuation { continuation in
            waitQueue.async { [self] in
                condition.lock()
                nextCaptureLeaseID &+= 1
                let lease = CaptureLease(id: nextCaptureLeaseID)
                activeCaptureLeaseID = lease.id
                while preflightActive {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume(returning: lease)
            }
        }
    }

    func endCapture(_ lease: CaptureLease) {
        condition.lock()
        guard activeCaptureLeaseID == lease.id else {
            condition.unlock()
            return
        }
        activeCaptureLeaseID = nil
        condition.broadcast()
        condition.unlock()
    }

    func beginPreflightIfIdle() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard activeCaptureLeaseID == nil, !preflightActive, !monitorActive else { return false }
        preflightActive = true
        return true
    }

    func endPreflight() {
        condition.lock()
        preflightActive = false
        condition.broadcast()
        condition.unlock()
    }

    func beginMonitorIfIdle() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard activeCaptureLeaseID == nil, !preflightActive, !monitorActive else { return false }
        monitorActive = true
        return true
    }

    func endMonitor() {
        condition.lock()
        monitorActive = false
        condition.broadcast()
        condition.unlock()
    }
}

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

    struct CaptureToken: Equatable {
        let owner: CaptureOwner
        fileprivate let lease: AudioInputActivityGate.CaptureLease
    }

    private let lock = NSLock()
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
        lock.lock()
        defer { lock.unlock() }
        return activeToken != nil
    }

    var currentOwner: CaptureOwner? {
        lock.lock()
        defer { lock.unlock() }
        return activeToken?.owner
    }

    /// Acquires the mic for a capture path. Suspends the level monitor when it
    /// was running. Overlapping captures are a state-machine bug upstream:
    /// they are logged, asserted in debug builds, and the new owner wins.
    func beginCapture(_ owner: CaptureOwner) async -> CaptureToken? {
        let lease = await activityGate.beginCapture()
        guard !Task.isCancelled else {
            activityGate.endCapture(lease)
            return nil
        }
        let token = CaptureToken(owner: owner, lease: lease)
        lock.lock()
        let previousOwner = activeToken?.owner
        activeToken = token
        let alreadySuspended = shouldResumeMonitor
        lock.unlock()

        if let previousOwner, previousOwner != owner {
            SapoLog.recording.error(
                "Capture overlap detected active=\(previousOwner.rawValue, privacy: .public) incoming=\(owner.rawValue, privacy: .public)"
            )
            assertionFailure("Two captures overlapped: \(previousOwner.rawValue) → \(owner.rawValue)")
        }

        guard !alreadySuspended else { return token }
        let didSuspend = suspendMonitor()
        if didSuspend {
            lock.lock()
            shouldResumeMonitor = true
            lock.unlock()
        }
        return token
    }

    /// Releases the mic when `token` still holds it; stale releases from an
    /// older capture are ignored so a late cleanup cannot kill a new session.
    func endCapture(_ token: CaptureToken) {
        lock.lock()
        guard activeToken == token else {
            lock.unlock()
            return
        }
        activeToken = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        lock.unlock()
        activityGate.endCapture(token.lease)

        if resume {
            resumeMonitor()
        }
    }

    /// Releases whatever capture is active. For generic cleanup paths (sleep
    /// abort, error teardown) that do not know which engine was recording.
    func endActiveCapture() {
        lock.lock()
        let token = activeToken
        activeToken = nil
        let resume = shouldResumeMonitor
        shouldResumeMonitor = false
        lock.unlock()
        if let token {
            activityGate.endCapture(token.lease)
        }

        if resume {
            resumeMonitor()
        }
    }
}
