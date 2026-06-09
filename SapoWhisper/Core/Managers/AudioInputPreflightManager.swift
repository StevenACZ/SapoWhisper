//
//  AudioInputPreflightManager.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os

/// Warms Core Audio route metadata after device changes so hotkey recording starts faster.
final class AudioInputPreflightManager {
    static let shared = AudioInputPreflightManager()

    private let deviceManager: AudioDeviceManager
    private let queue = DispatchQueue(label: "com.sapowhisper.audioPreflight", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    private var pendingWorkItem: DispatchWorkItem?
    private var hasStarted = false
    private var generation: UInt64 = 0

    /// A8: set by the ViewModel; evaluated on the main thread before each run
    /// so the preflight engine never touches the device mid-capture.
    var isCaptureActive: (() -> Bool)?

    private init(deviceManager: AudioDeviceManager = .shared) {
        self.deviceManager = deviceManager
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        deviceManager.routeChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.schedulePreflight(reason: "route-change")
            }
            .store(in: &cancellables)

        schedulePreflight(reason: "launch", delayOverride: 0.4)
    }

    func preflightSoon(reason: String = "manual") {
        schedulePreflight(reason: reason, delayOverride: 0.05)
    }

    private func schedulePreflight(reason: String, delayOverride: TimeInterval? = nil) {
        generation &+= 1
        let currentGeneration = generation
        pendingWorkItem?.cancel()

        let delay = max(0, delayOverride ?? deviceManager.captureRouteSettleDelay() + 0.05)
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPreflight(reason: reason, generation: currentGeneration)
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runPreflight(reason: String, generation: UInt64) {
        guard generation == self.generation else { return }

        // A8: defer instead of fighting an active capture for the device; the
        // retry keeps the cache warm for the route in place after recording.
        let captureActive = DispatchQueue.main.sync { isCaptureActive?() ?? false }
        if captureActive {
            SapoLog.audioRoute.info(
                "Audio input preflight deferred reason=\(reason, privacy: .public) capture-active"
            )
            DispatchQueue.main.async { [weak self] in
                self?.schedulePreflight(reason: "\(reason)-deferred", delayOverride: 1.0)
            }
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let selectedUID =
            UserDefaults.standard.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid

        deviceManager.refreshDevices()
        let deviceID =
            selectedUID == AudioDevice.systemDefault.uid
            ? deviceManager.getSystemDefaultInputDevice()
            : deviceManager.getDeviceID(for: selectedUID)

        _ = deviceID.flatMap { queryInputFormat(deviceID: $0) }
        warmAVAudioInputNode(deviceID: deviceID, selectedUID: selectedUID)

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SapoLog.audioRoute.info(
            "Audio input preflight finished reason=\(reason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms"
        )
    }

    private func warmAVAudioInputNode(deviceID: AudioDeviceID?, selectedUID: String) {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if selectedUID != AudioDevice.systemDefault.uid,
            let deviceID,
            let audioUnit = inputNode.audioUnit
        {
            var targetDeviceID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetDeviceID,
                UInt32(MemoryLayout<AudioObjectID>.size)
            )
        }

        _ = inputNode.outputFormat(forBus: 0)

        // L4: prepare()+reset() never touched the HAL, so the first recording
        // still paid full route setup. A brief muted start()/stop() forces the
        // I/O unit to open the device; the tap discards every buffer.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        inputNode.volume = 0
        engine.prepare()
        do {
            try engine.start()
            engine.stop()
        } catch {
            SapoLog.audioRoute.warning(
                "Audio input preflight start failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
        inputNode.removeTap(onBus: 0)
        engine.reset()
    }

    private func queryInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
