//
//  PreferredMicrophoneCoordinator.swift
//  SapoWhisper
//
//  Created by Codex on 9/4/26.
//

import Foundation
import Combine
import CoreAudio

/// Keeps the app's preferred microphone aligned with the macOS global default input.
final class PreferredMicrophoneCoordinator {

    static let shared = PreferredMicrophoneCoordinator()

    private let deviceManager: AudioDeviceManager
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var pendingReconciliation: DispatchWorkItem?
    private var hasStarted = false
    private var lastResolvedInputDeviceID: AudioDeviceID?

    private init(
        deviceManager: AudioDeviceManager = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.deviceManager = deviceManager
        self.userDefaults = userDefaults
        self.lastResolvedInputDeviceID = deviceManager.getSystemDefaultInputDevice()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        lastResolvedInputDeviceID = deviceManager.getSystemDefaultInputDevice()

        deviceManager.routeChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.scheduleReconciliation(announceFinalDevice: true)
            }
            .store(in: &cancellables)

        scheduleReconciliation(announceFinalDevice: false)
    }

    func applyUserSelection(uid: String) {
        userDefaults.set(uid, forKey: Constants.StorageKeys.selectedMicrophone)
        scheduleReconciliation(announceFinalDevice: false, delayOverride: 0)
    }

    private func scheduleReconciliation(
        announceFinalDevice: Bool,
        delayOverride: TimeInterval? = nil
    ) {
        pendingReconciliation?.cancel()

        let delay = max(0, delayOverride ?? deviceManager.captureRouteSettleDelay())
        let workItem = DispatchWorkItem { [weak self] in
            self?.reconcilePreferredMicrophone(announceFinalDevice: announceFinalDevice)
        }
        pendingReconciliation = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func reconcilePreferredMicrophone(announceFinalDevice: Bool) {
        deviceManager.refreshDevices()

        let preferredUID = selectedMicrophoneUID()
        let currentDefaultDeviceID = deviceManager.getSystemDefaultInputDevice()

        guard preferredUID != AudioDevice.systemDefault.uid else {
            updateResolvedInputDevice(
                currentDefaultDeviceID,
                announceFinalDevice: announceFinalDevice,
                forceAnnouncement: false
            )
            return
        }

        guard let preferredDeviceID = deviceManager.getDeviceID(for: preferredUID) else {
            print("🎙️ [preferred mic] preferred input missing, reverting to system default")
            userDefaults.set(AudioDevice.systemDefault.uid, forKey: Constants.StorageKeys.selectedMicrophone)
            updateResolvedInputDevice(
                currentDefaultDeviceID,
                announceFinalDevice: announceFinalDevice,
                forceAnnouncement: false
            )
            return
        }

        var finalDefaultDeviceID = currentDefaultDeviceID
        var restoredPreferredInput = false

        if currentDefaultDeviceID != preferredDeviceID {
            restoredPreferredInput = deviceManager.setSystemDefaultInputDevice(preferredDeviceID)
            finalDefaultDeviceID = restoredPreferredInput
                ? preferredDeviceID
                : deviceManager.getSystemDefaultInputDevice()

            let preferredDeviceName = deviceManager.getDeviceName(for: preferredDeviceID) ?? preferredUID
            if restoredPreferredInput {
                print("🎙️ [preferred mic] restored system input -> \(preferredDeviceName)")
            } else {
                print("⚠️ [preferred mic] failed to restore system input -> \(preferredDeviceName)")
            }
        } else {
            finalDefaultDeviceID = preferredDeviceID
        }

        updateResolvedInputDevice(
            finalDefaultDeviceID,
            announceFinalDevice: announceFinalDevice,
            forceAnnouncement: restoredPreferredInput
        )
    }

    private func updateResolvedInputDevice(
        _ deviceID: AudioDeviceID?,
        announceFinalDevice: Bool,
        forceAnnouncement: Bool
    ) {
        defer {
            lastResolvedInputDeviceID = deviceID
        }

        guard announceFinalDevice, let deviceID else { return }
        guard forceAnnouncement || deviceID != lastResolvedInputDeviceID else { return }
        guard let deviceName = deviceManager.getDeviceName(for: deviceID) else { return }
        deviceManager.publishDetectedDeviceName(deviceName)
    }

    private func selectedMicrophoneUID() -> String {
        userDefaults.string(forKey: Constants.StorageKeys.selectedMicrophone) ?? AudioDevice.systemDefault.uid
    }
}
