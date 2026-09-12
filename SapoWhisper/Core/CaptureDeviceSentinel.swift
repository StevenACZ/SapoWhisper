//
//  CaptureDeviceSentinel.swift
//  SapoWhisper
//

import AVFoundation
import CoreAudio
import Foundation
import os

/// A2: watches the bound input device and the engine configuration while a
/// capture is running, so a dead microphone or a route change surfaces as an
/// event instead of silently recording nothing.
///
/// Not thread-safe on its own: `begin`/`end` must be called from the capture's
/// setup queue, and events are delivered on that same queue (hence
/// nonisolated rather than the project's default MainActor isolation).
nonisolated final class CaptureDeviceSentinel {

    enum Event: String {
        case deviceDied = "device-died"
        case configurationChanged = "configuration-changed"
        case defaultInputChanged = "default-input-changed"
    }

    private let queue: DispatchQueue
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var generation: UInt64 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        end()
    }

    func begin(deviceID: AudioDeviceID, followsDefaultInput: Bool, onEvent: @escaping @Sendable (Event) -> Void) {
        end()
        observe(deviceID, address: Self.aliveAddress) {
            if !Self.isDeviceAlive(deviceID) { onEvent(.deviceDied) }
        }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration] {
            observe(
                deviceID,
                address: AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: selector == kAudioDevicePropertyNominalSampleRate
                        ? kAudioObjectPropertyScopeGlobal : kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
            ) { onEvent(.configurationChanged) }
        }
        if followsDefaultInput {
            observe(
                AudioObjectID(kAudioObjectSystemObject),
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ) { onEvent(.defaultInputChanged) }
        }
    }

    private func observe(_ object: AudioObjectID, address: AudioObjectPropertyAddress, action: @escaping @Sendable () -> Void) {
        var address = address
        let observedGeneration = generation
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard self?.generation == observedGeneration else { return }
            action()
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
        if status == noErr {
            listeners.append((object, address, listener))
        } else {
            SapoLog.audioRoute.warning(
                "Capture sentinel could not watch device-alive status=\(status, privacy: .public)"
            )
        }
    }

    func end() {
        generation &+= 1
        for (object, storedAddress, listener) in listeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        listeners.removeAll()
    }

    private static var aliveAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = aliveAddress
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }
}
