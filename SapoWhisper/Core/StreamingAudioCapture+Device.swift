//
//  StreamingAudioCapture+Device.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

extension StreamingAudioCapture {
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

    func beginDeviceSentinel(engine: AVAudioEngine, deviceID: AudioDeviceID?) {
        deviceSentinel.begin(engine: engine, deviceID: deviceID) { [weak self] event in
            self?.handleCaptureInterruption(event: event)
        }
    }

    /// Runs on `audioSetupQueue`. Rebuilds the engine after a device death or
    /// configuration change, falling back to the system default input when the
    /// selected device is gone. Streaming chunks keep flowing to the same
    /// handler; a failed rebuild reports a terminal interruption.
    func handleCaptureInterruption(event: CaptureDeviceSentinel.Event) {
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
        let inputNode = engine.inputNode

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

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        engine.prepare()
        try engine.start()

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
