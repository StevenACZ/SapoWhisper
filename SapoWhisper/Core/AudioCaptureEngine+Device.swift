//
//  AudioCaptureEngine+Device.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

nonisolated extension AudioCaptureEngine {
    func prepareInputSession(
        deviceUID: String,
        generation: UInt64,
        deadline: TimeInterval
    ) async throws -> InputOnlyAudioSession {
        let quarantine = AudioInputSetupQuarantine.shared
        let failures = inputFailures
        guard let preparation = quarantine.preparationContext() else {
            throw RecordingError.inputSetupTimedOut
        }
        let request = AudioDeadlineRequest<InputOnlyAudioSession>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let attempt = AudioDeadlineAttempt(
                    timeout: deadline,
                    operation: "capture-input-only",
                    worker: preparation.worker,
                    work: { [self] in try makeInputSession(deviceUID: deviceUID, generation: generation, failures: failures) },
                    cleanup: { $0.close() },
                    onQuarantine: { _ in quarantine.quarantine(epoch: preparation.epoch) },
                    completion: { continuation.resume(with: $0) }
                )
                request.install(attempt)
                attempt.start()
            }
        } onCancel: {
            self.invalidateSetupGeneration()
            request.cancel()
        }
    }

    private func makeInputSession(
        deviceUID: String, generation: UInt64, failures: CaptureInputFailureState
    ) throws -> InputOnlyAudioSession {
        let manager = AudioDeviceManager.shared
        manager.refreshDevices()
        guard let deviceID = manager.resolveSelectedInputDeviceID(for: deviceUID) else {
            throw RecordingError.inputDeviceUnavailable
        }
        guard isSetupGenerationCurrent(generation) else { throw CancellationError() }
        let token = failures.beginInput()
        return try InputOnlyAudioSession.prepare(
            deviceID: deviceID,
            onBuffer: { [weak self] buffer in
                self?.processAudioBuffer(buffer)
            },
            onError: { [weak self] status in
                failures.record(status, for: token)
                guard let self else { return }
                self.audioSetupQueue.async {
                    guard self.isSetupGenerationCurrent(generation), failures.shouldNotify(for: token) else { return }
                    self.reportCaptureInterruption(reason: "input-render(\(status))")
                }
            }
        )
    }

    // MARK: - A2: capture interruption recovery

    static let captureHealthProbeDelay: TimeInterval = 0.3
    static let captureHealthyBufferMaxAge: TimeInterval = 0.5

    func beginDeviceSentinel(session: InputOnlyAudioSession, generation: UInt64) {
        deviceSentinel.begin(
            deviceID: session.deviceID,
            followsDefaultInput: currentCaptureDeviceUID() == AudioDevice.systemDefault.uid
        ) { [weak self] event in
            self?.handleCaptureInterruption(event: event, generation: generation)
        }
    }

    func handleCaptureInterruption(event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), inputSession != nil else { return }

        switch event {
        case .deviceDied, .defaultInputChanged:
            recoverCapture(afterEvent: event, generation: generation)
        case .configurationChanged:
            scheduleCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// Coalesces configuration-change bursts into one deferred health check;
    /// the sentinel stays armed and the engine keeps running while it waits.
    private func scheduleCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard !captureHealthProbePending, let session = inputSession else { return }
        captureHealthProbePending = true
        SapoLog.recording.info(
            "\(self.mode.logLabel, privacy: .public) configuration changed, probing health")
        let delay =
            AudioDeviceManager.shared.transportType(for: session.deviceID) == .bluetooth
            ? 3.0 : Self.captureHealthProbeDelay
        audioSetupQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
            guard let self, let session, self.inputSession === session else { return }
            self.runCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// A paused capture can never satisfy the health condition, so recovering
    /// one would restart the engine behind the user's pause; `resumeRecording`
    /// owns that restart.
    func shouldRecoverAfterConfigurationChange(isEngineRunning: Bool, lastBufferAge: TimeInterval?) -> Bool {
        guard !isPaused else { return false }
        guard isEngineRunning, let lastBufferAge else { return true }
        return lastBufferAge > Self.captureHealthyBufferMaxAge
    }

    /// Runs on `audioSetupQueue`. Leaves a healthy engine (still running,
    /// buffers still arriving) untouched and rebuilds only a dead stream.
    private func runCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        captureHealthProbePending = false
        guard isSetupGenerationCurrent(generation), let engine = inputSession else { return }

        let lastBuffer = currentLastInputBufferTime()
        let lastBufferAge: TimeInterval? = lastBuffer > 0 ? CFAbsoluteTimeGetCurrent() - lastBuffer : nil
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(engine.deviceID, &address, 0, nil, &size, &sampleRate)
        let formatChanged = formatStatus != noErr || sampleRate != engine.format.sampleRate
        guard formatChanged || shouldRecoverAfterConfigurationChange(isEngineRunning: engine.isRunning, lastBufferAge: lastBufferAge) else {
            captureRecoveryAttempts = 0
            let bufferAgeMs = lastBufferAge.map { Int($0 * 1000) } ?? -1
            SapoLog.recording.info(
                "\(self.mode.logLabel, privacy: .public) capture kept after configuration change paused=\(self.isPaused, privacy: .public) bufferAgeMs=\(bufferAgeMs, privacy: .public)"
            )
            return
        }
        recoverCapture(afterEvent: event, generation: generation)
    }

    /// Runs on `audioSetupQueue`. Rebuilds the engine after a device death or
    /// a dead post-change stream. Streaming chunks keep
    /// flowing to the same handler; a failed rebuild reports a terminal
    /// interruption so the owner can abort preserving the WAV.
    private func recoverCapture(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), let oldEngine = inputSession else { return }

        deviceSentinel.end()
        captureRecoveryAttempts += 1
        let attempt = captureRecoveryAttempts
        SapoLog.recording.warning(
            "\(self.mode.logLabel, privacy: .public) capture interrupted event=\(event.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )

        inputFailures.stopNotifying()
        oldEngine.close()
        inputSession = nil
        captureHealthProbePending = false

        guard attempt <= 2 else {
            reportCaptureInterruption(reason: "\(event.rawValue) recovery-exhausted")
            return
        }

        do {
            try rebuildCaptureEngine(generation: generation)
        } catch {
            let detail = LogSanitizer.errorDiagnostic(error, state: "capture-recovery")
            SapoLog.recording.error(
                "\(self.mode.logLabel, privacy: .public) capture recovery failed \(detail, privacy: .public)"
            )
            reportCaptureInterruption(reason: "\(event.rawValue) rebuild-failed")
        }
    }

    private func rebuildCaptureEngine(generation: UInt64) throws {
        let deviceUID = currentCaptureDeviceUID()
        let session = try makeInputSession(deviceUID: deviceUID, generation: generation, failures: inputFailures)
        var adopted = false
        defer { if !adopted { session.close() } }
        resetLastInputBufferTime()
        if !isPaused { try session.start() }
        inputSession = session
        adopted = true
        beginDeviceSentinel(session: session, generation: generation)
        scheduleCaptureHealthProbe(afterEvent: .configurationChanged, generation: generation)
        SapoLog.recording.info("Capture input restored hz=\(Int(session.format.sampleRate), privacy: .public)")
    }

    private func reportCaptureInterruption(reason: String) {
        invalidateSetupGeneration()
        let callback = onCaptureInterrupted
        DispatchQueue.main.async {
            callback?(reason)
        }
    }
}
