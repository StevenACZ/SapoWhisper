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
/// setup queue, and events are delivered on that same queue.
final class CaptureDeviceSentinel {

    enum Event: String {
        case deviceDied = "device-died"
        case configurationChanged = "configuration-changed"
    }

    private let queue: DispatchQueue
    private var observedDeviceID: AudioDeviceID?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        end()
    }

    func begin(engine: AVAudioEngine, deviceID: AudioDeviceID?, onEvent: @escaping (Event) -> Void) {
        end()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [queue] _ in
            queue.async { onEvent(.configurationChanged) }
        }

        guard let deviceID else { return }

        var address = Self.aliveAddress
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard !Self.isDeviceAlive(deviceID) else { return }
            onEvent(.deviceDied)
        }

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)
        if status == noErr {
            observedDeviceID = deviceID
            aliveListener = listener
        } else {
            SapoLog.audioRoute.warning(
                "Capture sentinel could not watch device-alive status=\(status, privacy: .public)"
            )
        }
    }

    func end() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }

        if let observedDeviceID, let aliveListener {
            var address = Self.aliveAddress
            AudioObjectRemovePropertyListenerBlock(observedDeviceID, &address, queue, aliveListener)
        }
        observedDeviceID = nil
        aliveListener = nil
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
