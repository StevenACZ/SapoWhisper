//
//  PreferredMicrophoneCoordinator.swift
//  SapoWhisper
import Combine
import CoreAudio
import Foundation
import os

protocol PreferredMicrophoneDeviceManaging: AnyObject {
    var routeChanges: AnyPublisher<Void, Never> { get }

    func refreshDevices()
    func getSystemDefaultInputDevice() -> AudioDeviceID?
    func getDeviceID(for uid: String) -> AudioDeviceID?
    func getDeviceName(for deviceID: AudioDeviceID) -> String?
    func transportType(for deviceID: AudioDeviceID) -> AudioDeviceTransport
    func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool
    func captureRouteSettleDelay() -> TimeInterval
    func publishDeviceChange(_ announcement: DeviceChangeAnnouncement)
}

extension AudioDeviceManager: PreferredMicrophoneDeviceManaging {}

/// Keeps the app's preferred microphone aligned with the macOS global default input.
final class PreferredMicrophoneCoordinator {

    static let shared = PreferredMicrophoneCoordinator()
    private static let restoreRetryDelays: [TimeInterval] = [0.25, 0.75, 1.5]

    private let deviceManager: any PreferredMicrophoneDeviceManaging
    private let userDefaults: UserDefaults
    private let scheduleWork: (TimeInterval, DispatchWorkItem) -> Void
    private var cancellables = Set<AnyCancellable>()
    private var pendingReconciliation: DispatchWorkItem?
    private var hasStarted = false
    private var externalDefaultInputSessionIsActive = false
    private var lastResolvedInputDeviceID: AudioDeviceID?

    init(
        deviceManager: any PreferredMicrophoneDeviceManaging = AudioDeviceManager.shared,
        userDefaults: UserDefaults = .standard,
        scheduleWork: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    ) {
        self.deviceManager = deviceManager
        self.userDefaults = userDefaults
        self.scheduleWork = scheduleWork
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
                self?.requestReconciliation(reason: "audio-route-change")
            }
            .store(in: &cancellables)

        requestReconciliation(reason: "launch", announceFinalDevice: false)
    }

    /// HUD phase 1: the system default input already moved to a new device
    /// but the route is still settling — show "connecting" immediately so the
    /// user sees the switch happening instead of a silent gap until "ready".
    private func announceConnectingIfDefaultMoved() {
        guard let currentDefaultID = deviceManager.getSystemDefaultInputDevice(),
            currentDefaultID != lastResolvedInputDeviceID,
            let deviceName = deviceManager.getDeviceName(for: currentDefaultID)
        else { return }

        let preferredUID = selectedMicrophoneUID()
        if preferredUID != AudioDevice.systemDefault.uid {
            guard deviceManager.getDeviceID(for: preferredUID) == currentDefaultID else { return }
        }

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
        requestReconciliation(
            reason: "user-selection",
            announceFinalDevice: false,
            delayOverride: 0
        )
        AudioInputPreflightManager.shared.preflightSoon(reason: "mic-selection")
    }

    func requestReconciliation(
        reason: String,
        announceFinalDevice: Bool = true,
        delayOverride: TimeInterval? = nil
    ) {
        SapoLog.audioRoute.info(
            "Primary microphone reconciliation requested reason=\(reason, privacy: .public)"
        )
        scheduleReconciliation(
            announceFinalDevice: announceFinalDevice,
            delayOverride: delayOverride,
            restoreAttempt: 0
        )
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
        guard !externalDefaultInputSessionIsActive else { return false }
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
        } else {
            scheduleRestoreRetry(announceFinalDevice: false, restoreAttempt: 0)
        }
        return changed
    }

    /// Temporarily lets a companion app own the system default input without
    /// the primary-microphone pin racing to restore the user's saved device.
    func beginExternalDefaultInputSession() {
        externalDefaultInputSessionIsActive = true
        pendingReconciliation?.cancel()
        pendingReconciliation = nil
        SapoLog.audioRoute.info("External default-input session began")
    }

    /// Restores the normal pin policy after capture has had time to release its
    /// route. The saved selection itself is never changed by the override.
    func endExternalDefaultInputSession() {
        guard externalDefaultInputSessionIsActive else { return }
        externalDefaultInputSessionIsActive = false
        requestReconciliation(
            reason: "external-session-ended",
            delayOverride: 0.4
        )
        SapoLog.audioRoute.info("External default-input session ended")
    }

    func reconcileNow(announceFinalDevice: Bool = true) {
        reconcilePreferredMicrophone(
            announceFinalDevice: announceFinalDevice,
            restoreAttempt: 0
        )
    }

    private func scheduleReconciliation(
        announceFinalDevice: Bool,
        delayOverride: TimeInterval? = nil,
        restoreAttempt: Int
    ) {
        guard !externalDefaultInputSessionIsActive else { return }
        pendingReconciliation?.cancel()

        let delay = max(0, delayOverride ?? deviceManager.captureRouteSettleDelay())
        let workItem = DispatchWorkItem { [weak self] in
            self?.reconcilePreferredMicrophone(
                announceFinalDevice: announceFinalDevice,
                restoreAttempt: restoreAttempt
            )
        }
        pendingReconciliation = workItem

        scheduleWork(delay, workItem)
    }

    private func reconcilePreferredMicrophone(
        announceFinalDevice: Bool,
        restoreAttempt: Int
    ) {
        guard !externalDefaultInputSessionIsActive else { return }
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
            SapoLog.audioRoute.warning(
                "Preferred input temporarily unavailable; preserving selection"
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
                scheduleRestoreRetry(
                    announceFinalDevice: announceFinalDevice,
                    restoreAttempt: restoreAttempt
                )
            }
        } else if currentDefaultDeviceID == preferredDeviceID {
            finalDefaultDeviceID = preferredDeviceID
        }

        updateResolvedInputDevice(
            finalDefaultDeviceID,
            announceFinalDevice: announceFinalDevice,
            forceAnnouncement: restoredPreferredInput
        )
    }

    private func scheduleRestoreRetry(
        announceFinalDevice: Bool,
        restoreAttempt: Int
    ) {
        guard restoreAttempt < Self.restoreRetryDelays.count else {
            SapoLog.audioRoute.error("Primary microphone restore retries exhausted")
            return
        }

        let delay = Self.restoreRetryDelays[restoreAttempt]
        SapoLog.audioRoute.info(
            "Primary microphone restore retry scheduled attempt=\(restoreAttempt + 1, privacy: .public) delayMs=\(Int(delay * 1_000), privacy: .public)"
        )
        scheduleReconciliation(
            announceFinalDevice: announceFinalDevice,
            delayOverride: delay,
            restoreAttempt: restoreAttempt + 1
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
