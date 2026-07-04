//
//  PreferredMicrophoneCoordinator.swift
//  SapoWhisper
//
//  Created by Codex on 9/4/26.
//

import Combine
import CoreAudio
import Foundation
import os

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
                self?.announceConnectingIfDefaultMoved()
                self?.scheduleReconciliation(announceFinalDevice: true)
            }
            .store(in: &cancellables)

        scheduleReconciliation(announceFinalDevice: false)
    }

    /// HUD phase 1: the system default input already moved to a new device
    /// but the route is still settling — show "connecting" immediately so the
    /// user sees the switch happening instead of a silent gap until "ready".
    private func announceConnectingIfDefaultMoved() {
        guard let currentDefaultID = deviceManager.getSystemDefaultInputDevice(),
            currentDefaultID != lastResolvedInputDeviceID,
            let deviceName = deviceManager.getDeviceName(for: currentDefaultID)
        else { return }

        deviceManager.publishDeviceChange(
            DeviceChangeAnnouncement(
                deviceName: deviceName,
                transport: deviceManager.transportType(for: currentDefaultID),
                phase: .connecting
            )
        )
    }

    func applyUserSelection(uid: String) {
        userDefaults.set(uid, forKey: Constants.StorageKeys.selectedMicrophone)
        scheduleReconciliation(announceFinalDevice: false, delayOverride: 0)
        AudioInputPreflightManager.shared.preflightSoon(reason: "mic-selection")
    }

    /// Synchronous pre-capture sync: when an explicit mic is selected, make it
    /// the system default input right now. A capture that opens a device that
    /// is NOT the system default pays the full route setup every time — on
    /// Bluetooth (AirPods) that is the whole 1–3 s A2DP→HFP handshake, because
    /// macOS only keeps the link warm for the default input. Aligning both
    /// (what the app shows = what System Settings shows) makes the fast path
    /// the only path. Returns true when the default actually changed, so the
    /// caller can respect the route settle window.
    @discardableResult
    func ensureSystemDefaultMatchesSelection() -> Bool {
        guard isPrimaryMicPinned else { return false }
        let preferredUID = selectedMicrophoneUID()
        guard preferredUID != AudioDevice.systemDefault.uid else { return false }

        if deviceManager.getDeviceID(for: preferredUID) == nil {
            deviceManager.refreshDevices()
        }
        guard let preferredDeviceID = deviceManager.getDeviceID(for: preferredUID),
            let currentDefaultID = deviceManager.getSystemDefaultInputDevice(),
            currentDefaultID != preferredDeviceID
        else { return false }

        let changed = deviceManager.setSystemDefaultInputDevice(preferredDeviceID)
        if changed {
            lastResolvedInputDeviceID = preferredDeviceID
            let deviceName = deviceManager.getDeviceName(for: preferredDeviceID) ?? preferredUID
            SapoLog.audioRoute.info(
                "System default input synced to selection device=\(deviceName, privacy: .public)"
            )
        }
        return changed
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
            SapoLog.audioRoute.warning("Preferred input missing, reverting to system default")
            userDefaults.set(AudioDevice.systemDefault.uid, forKey: Constants.StorageKeys.selectedMicrophone)
            // HUD fallback phase: the mic the user chose is gone; make the
            // silent revert visible so recordings landing on another device
            // don't read as a bug.
            if announceFinalDevice, let currentDefaultDeviceID,
                let fallbackName = deviceManager.getDeviceName(for: currentDefaultDeviceID)
            {
                deviceManager.publishDeviceChange(
                    DeviceChangeAnnouncement(
                        deviceName: fallbackName,
                        transport: deviceManager.transportType(for: currentDefaultDeviceID),
                        phase: .fallback
                    )
                )
                lastResolvedInputDeviceID = currentDefaultDeviceID
                return
            }
            updateResolvedInputDevice(
                currentDefaultDeviceID,
                announceFinalDevice: announceFinalDevice,
                forceAnnouncement: false
            )
            return
        }

        var finalDefaultDeviceID = currentDefaultDeviceID
        var restoredPreferredInput = false

        if currentDefaultDeviceID != preferredDeviceID, isPrimaryMicPinned {
            restoredPreferredInput = deviceManager.setSystemDefaultInputDevice(preferredDeviceID)
            finalDefaultDeviceID =
                restoredPreferredInput
                ? preferredDeviceID
                : deviceManager.getSystemDefaultInputDevice()

            let preferredDeviceName = deviceManager.getDeviceName(for: preferredDeviceID) ?? preferredUID
            if restoredPreferredInput {
                SapoLog.audioRoute.info(
                    "Preferred input restored device=\(preferredDeviceName, privacy: .public)"
                )
            } else {
                SapoLog.audioRoute.warning(
                    "Preferred input restore failed device=\(preferredDeviceName, privacy: .public)"
                )
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
        deviceManager.publishDeviceChange(
            DeviceChangeAnnouncement(
                deviceName: deviceName,
                transport: deviceManager.transportType(for: deviceID),
                phase: .ready
            )
        )
    }

    private func selectedMicrophoneUID() -> String {
        userDefaults.string(forKey: Constants.StorageKeys.selectedMicrophone) ?? AudioDevice.systemDefault.uid
    }

    /// "Primary microphone" pin (default ON): an explicit selection is imposed
    /// as the system default input and restored after every device swap, so
    /// connecting AirPods or a headset never steals the mic.
    private var isPrimaryMicPinned: Bool {
        (userDefaults.object(forKey: Constants.StorageKeys.pinPrimaryMicrophone) as? Bool) ?? true
    }
}
