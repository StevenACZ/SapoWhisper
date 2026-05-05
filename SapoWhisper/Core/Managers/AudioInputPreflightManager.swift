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
        engine.prepare()
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
