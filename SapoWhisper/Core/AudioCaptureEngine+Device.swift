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
    /// Binds the preferred input device. Returns the device's actual hardware format if bound.
    /// Accepts `deviceUID` as a parameter so it can be called safely from a background queue
    /// without reading `self.selectedDeviceUID` across thread boundaries.
    /// A missing selected device is not an error: capture falls through to the
    /// system default input instead of failing the whole take.
    func bindPreferredInputDevice(to inputNode: AVAudioInputNode, deviceUID: String) throws -> AVAudioFormat? {
        guard deviceUID != AudioDevice.systemDefault.uid else { return nil }

        let deviceManager = AudioDeviceManager.shared
        guard let deviceID = deviceManager.getDeviceID(for: deviceUID) else { return nil }
        guard let audioUnit = inputNode.audioUnit else {
            throw RecordingError.deviceSelectionFailed(-1)
        }

        var currentDeviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let getStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            &size
        )

        let deviceName = deviceManager.getDeviceName(for: deviceID) ?? deviceUID
        if getStatus == noErr, currentDeviceID == deviceID {
            SapoLog.recording.info(
                "\(self.mode.logLabel, privacy: .public) input already bound device=\(deviceName, privacy: .public)"
            )
            return queryDeviceInputFormat(deviceID: deviceID)
        }

        var targetDeviceID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        guard setStatus == noErr else {
            SapoLog.recording.error(
                "\(self.mode.logLabel, privacy: .public) bind failed device=\(deviceName, privacy: .public) status=\(setStatus, privacy: .public)"
            )
            throw RecordingError.deviceSelectionFailed(setStatus)
        }

        SapoLog.recording.info(
            "\(self.mode.logLabel, privacy: .public) bound input device=\(deviceName, privacy: .public)")
        return queryDeviceInputFormat(deviceID: deviceID)
    }

    /// Queries the actual hardware input format of a device via Core Audio (bypasses AVAudioEngine cache)
    func queryDeviceInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard status == noErr else {
            SapoLog.recording.warning(
                "\(self.mode.logLabel, privacy: .public) could not query device hw format status=\(status, privacy: .public)"
            )
            return nil
        }

        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: - A2: capture interruption recovery

    static let captureHealthProbeDelay: TimeInterval = 0.3
    static let captureHealthyBufferMaxAge: TimeInterval = 0.5

    func beginDeviceSentinel(engine: AVAudioEngine, deviceID: AudioDeviceID?, generation: UInt64) {
        deviceSentinel.begin(engine: engine, deviceID: deviceID) { [weak self] event in
            self?.handleCaptureInterruption(event: event, generation: generation)
        }
    }

    /// Runs on `audioSetupQueue`. A dead device rebuilds right away; a
    /// configuration change is probed first because AVAudioEngine posts it for
    /// benign renegotiations (binding a USB mic fires one right after start)
    /// while audio keeps flowing — tearing down a healthy engine re-triggers
    /// the notification until recovery is exhausted.
    func handleCaptureInterruption(event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), audioEngine != nil else { return }

        switch event {
        case .deviceDied:
            recoverCapture(afterEvent: event, generation: generation)
        case .configurationChanged:
            scheduleCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// Coalesces configuration-change bursts into one deferred health check;
    /// the sentinel stays armed and the engine keeps running while it waits.
    private func scheduleCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard !captureHealthProbePending else { return }
        captureHealthProbePending = true
        SapoLog.recording.info(
            "\(self.mode.logLabel, privacy: .public) configuration changed, probing health")
        audioSetupQueue.asyncAfter(deadline: .now() + Self.captureHealthProbeDelay) { [weak self] in
            self?.runCaptureHealthProbe(afterEvent: event, generation: generation)
        }
    }

    /// A paused capture can never satisfy the health condition (`isRunning` is
    /// false and no buffers arrive), so recovering one would restart the engine
    /// behind the user's pause and burn the recovery budget until the session
    /// aborts. `resumeRecording` owns the restart instead.
    func shouldRecoverAfterConfigurationChange(isEngineRunning: Bool, lastBufferAge: TimeInterval?) -> Bool {
        guard !isPaused else { return false }
        guard isEngineRunning, let lastBufferAge else { return true }
        return lastBufferAge > Self.captureHealthyBufferMaxAge
    }

    /// Runs on `audioSetupQueue`. Leaves a healthy engine (still running,
    /// buffers still arriving) untouched and rebuilds only a dead stream.
    private func runCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        captureHealthProbePending = false
        guard isSetupGenerationCurrent(generation), let engine = audioEngine else { return }

        let lastBuffer = currentLastInputBufferTime()
        let lastBufferAge: TimeInterval? = lastBuffer > 0 ? CFAbsoluteTimeGetCurrent() - lastBuffer : nil
        guard shouldRecoverAfterConfigurationChange(isEngineRunning: engine.isRunning, lastBufferAge: lastBufferAge) else {
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
    /// a dead post-change stream (rebinding the selected device, or falling
    /// back to the system default when it is gone). Streaming chunks keep
    /// flowing to the same handler; a failed rebuild reports a terminal
    /// interruption so the owner can abort preserving the WAV.
    private func recoverCapture(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) {
        guard isSetupGenerationCurrent(generation), let oldEngine = audioEngine else { return }

        deviceSentinel.end()
        captureRecoveryAttempts += 1
        let attempt = captureRecoveryAttempts
        SapoLog.recording.warning(
            "\(self.mode.logLabel, privacy: .public) capture interrupted event=\(event.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )

        // Teardown races the same route churn that triggered recovery; a
        // guarded exception here just means the engine is already dead.
        try? AudioEngineGuard.run("recovery-teardown") {
            oldEngine.inputNode.removeTap(onBus: 0)
            oldEngine.stop()
            oldEngine.reset()
        }
        audioEngine = nil

        guard attempt <= 2 else {
            reportCaptureInterruption(reason: "\(event.rawValue) recovery-exhausted")
            return
        }

        do {
            try rebuildCaptureEngine(afterEvent: event, generation: generation)
        } catch {
            SapoLog.recording.error(
                "\(self.mode.logLabel, privacy: .public) capture recovery failed error=\(error.localizedDescription, privacy: .public)"
            )
            reportCaptureInterruption(reason: "\(event.rawValue) rebuild-failed")
        }
    }

    private func rebuildCaptureEngine(afterEvent event: CaptureDeviceSentinel.Event, generation: UInt64) throws {
        let engine = AVAudioEngine()
        let inputNode = try AudioEngineGuard.inputNode(of: engine, operation: "\(mode.opPrefix)-rebuild-input-node")

        var deviceUID = currentCaptureDeviceUID()
        var boundDeviceID: AudioDeviceID?
        var hwFormat: AVAudioFormat?

        if deviceUID != AudioDevice.systemDefault.uid {
            AudioDeviceManager.shared.refreshDevices()
            if event != .deviceDied,
                let format = try? bindPreferredInputDevice(to: inputNode, deviceUID: deviceUID)
            {
                hwFormat = format
                boundDeviceID = AudioDeviceManager.shared.getDeviceID(for: deviceUID)
            } else {
                // The selected device is gone: keep capturing on the system
                // default instead of recording silence for the rest of the take.
                deviceUID = AudioDevice.systemDefault.uid
                setCaptureDeviceUID(deviceUID)
                SapoLog.recording.warning(
                    "\(self.mode.logLabel, privacy: .public) falling back to system default input")
            }
        }

        let tapFormat = hwFormat ?? inputNode.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw RecordingError.invalidFormat
        }

        // A health probe after this rebuild must see buffers from the new
        // engine, not a fresh-looking timestamp left by the dead one.
        resetLastInputBufferTime()
        try AudioEngineGuard.installTap(
            on: inputNode, bufferSize: tapBufferSize, format: tapFormat,
            operation: "\(mode.opPrefix)-rebuild-install-tap"
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        // Rebuilding behind a pause repairs the tap and the device binding, but
        // starting the engine would capture audio the user asked to stop.
        let paused = isPaused
        if paused {
            try AudioEngineGuard.run("\(mode.opPrefix)-rebuild-engine-prepare") { engine.prepare() }
        } else {
            try AudioEngineGuard.prepareAndStart(engine, operation: "\(mode.opPrefix)-rebuild-engine-start")
        }

        audioEngine = engine
        beginDeviceSentinel(engine: engine, deviceID: boundDeviceID, generation: generation)
        let inputDescription = deviceUID == AudioDevice.systemDefault.uid ? "system-default" : deviceUID
        SapoLog.recording.info(
            "\(self.mode.logLabel, privacy: .public) capture recovered input=\(inputDescription, privacy: .public) hz=\(Int(tapFormat.sampleRate), privacy: .public) paused=\(paused, privacy: .public)"
        )
    }

    private func reportCaptureInterruption(reason: String) {
        invalidateSetupGeneration()
        let callback = onCaptureInterrupted
        DispatchQueue.main.async {
            callback?(reason)
        }
    }
}
