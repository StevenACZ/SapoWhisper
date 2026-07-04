//
//  StreamingAudioCapture+Device.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

nonisolated extension StreamingAudioCapture {
    func bindPreferredInputDevice(to inputNode: AVAudioInputNode, deviceUID: String) throws -> AVAudioFormat? {
        guard deviceUID != AudioDevice.systemDefault.uid else { return nil }
        let deviceManager = AudioDeviceManager.shared
        guard let deviceID = deviceManager.getDeviceID(for: deviceUID),
            let audioUnit = inputNode.audioUnit
        else {
            throw RecordingError.deviceSelectionFailed(-1)
        }

        var targetDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        guard status == noErr else {
            throw RecordingError.deviceSelectionFailed(status)
        }

        return queryDeviceInputFormat(deviceID: deviceID)
    }

    func queryDeviceInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: - A2: capture interruption recovery

    static let captureHealthProbeDelay: TimeInterval = 0.3
    static let captureHealthyBufferMaxAge: TimeInterval = 0.5

    func beginDeviceSentinel(engine: AVAudioEngine, deviceID: AudioDeviceID?) {
        deviceSentinel.begin(engine: engine, deviceID: deviceID) { [weak self] event in
            self?.handleCaptureInterruption(event: event)
        }
    }

    /// Runs on `audioSetupQueue`. A dead device rebuilds right away; a
    /// configuration change is probed first because AVAudioEngine posts it for
    /// benign renegotiations (binding a USB mic fires one right after start)
    /// while audio keeps flowing — tearing down a healthy engine re-triggers
    /// the notification until recovery is exhausted.
    func handleCaptureInterruption(event: CaptureDeviceSentinel.Event) {
        guard isCaptureActiveFlag(), audioEngine != nil else { return }

        switch event {
        case .deviceDied:
            recoverCapture(afterEvent: event)
        case .configurationChanged:
            scheduleCaptureHealthProbe(afterEvent: event)
        }
    }

    /// Coalesces configuration-change bursts into one deferred health check;
    /// the sentinel stays armed and the engine keeps running while it waits.
    private func scheduleCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event) {
        guard !captureHealthProbePending else { return }
        captureHealthProbePending = true
        SapoLog.recording.info("Streaming capture configuration changed, probing health")
        audioSetupQueue.asyncAfter(deadline: .now() + Self.captureHealthProbeDelay) { [weak self] in
            self?.runCaptureHealthProbe(afterEvent: event)
        }
    }

    /// Runs on `audioSetupQueue`. Leaves a healthy engine (still running,
    /// buffers still arriving) untouched and rebuilds only a dead stream.
    private func runCaptureHealthProbe(afterEvent event: CaptureDeviceSentinel.Event) {
        captureHealthProbePending = false
        guard isCaptureActiveFlag(), let engine = audioEngine else { return }

        let lastBuffer = currentLastInputBufferTime()
        let bufferAge = CFAbsoluteTimeGetCurrent() - lastBuffer
        if engine.isRunning, lastBuffer > 0, bufferAge <= Self.captureHealthyBufferMaxAge {
            captureRecoveryAttempts = 0
            SapoLog.recording.info(
                "Streaming capture healthy after configuration change bufferAgeMs=\(Int(bufferAge * 1000), privacy: .public)"
            )
            return
        }
        recoverCapture(afterEvent: event)
    }

    /// Runs on `audioSetupQueue`. Rebuilds the engine after a device death or
    /// a dead post-change stream, falling back to the system default input
    /// when the selected device is gone. Streaming chunks keep flowing to the
    /// same handler; a failed rebuild reports a terminal interruption.
    private func recoverCapture(afterEvent event: CaptureDeviceSentinel.Event) {
        guard isCaptureActiveFlag(), let oldEngine = audioEngine else { return }

        deviceSentinel.end()
        captureRecoveryAttempts += 1
        let attempt = captureRecoveryAttempts
        SapoLog.recording.warning(
            "Streaming capture interrupted event=\(event.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )

        oldEngine.inputNode.removeTap(onBus: 0)
        oldEngine.stop()
        oldEngine.reset()
        audioEngine = nil

        guard attempt <= 2 else {
            reportCaptureInterruption(reason: "\(event.rawValue) recovery-exhausted")
            return
        }

        do {
            try rebuildCaptureEngine(afterEvent: event)
        } catch {
            SapoLog.recording.error(
                "Streaming capture recovery failed error=\(error.localizedDescription, privacy: .public)"
            )
            reportCaptureInterruption(reason: "\(event.rawValue) rebuild-failed")
        }
    }

    private func rebuildCaptureEngine(afterEvent event: CaptureDeviceSentinel.Event) throws {
        let engine = AVAudioEngine()
        let inputNode = try AudioEngineGuard.inputNode(of: engine, operation: "streaming-rebuild-input-node")

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
                // default instead of streaming silence for the rest of the take.
                deviceUID = AudioDevice.systemDefault.uid
                setCaptureDeviceUID(deviceUID)
                SapoLog.recording.warning("Streaming capture falling back to system default input")
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
            operation: "streaming-rebuild-install-tap"
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        try AudioEngineGuard.prepareAndStart(engine, operation: "streaming-rebuild-engine-start")

        audioEngine = engine
        beginDeviceSentinel(engine: engine, deviceID: boundDeviceID)
        let inputDescription =
            deviceUID == AudioDevice.systemDefault.uid ? "system-default" : deviceUID
        SapoLog.recording.info(
            "Streaming capture recovered input=\(inputDescription, privacy: .public) hz=\(Int(tapFormat.sampleRate), privacy: .public)"
        )
    }

    private func reportCaptureInterruption(reason: String) {
        setCaptureActive(false)
        let callback = onCaptureInterrupted
        DispatchQueue.main.async {
            callback?(reason)
        }
    }
}
