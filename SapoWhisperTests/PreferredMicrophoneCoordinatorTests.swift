import Combine
import CoreAudio
import Foundation
import Testing

@testable import SapoWhisper

@Suite("Preferred microphone coordinator")
@MainActor
struct PreferredMicrophoneCoordinatorTests {
    @Test("A temporarily missing preferred microphone stays selected")
    func preservesMissingPreference() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("razer", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(true, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 2)
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults
        )

        coordinator.reconcileNow()

        #expect(defaults.string(forKey: Constants.StorageKeys.selectedMicrophone) == "razer")
        #expect(devices.defaultInputSetRequests.isEmpty)
        #expect(devices.announcements.isEmpty)
    }

    @Test("A missing explicit microphone never resolves to the system default")
    func missingExplicitInputDoesNotFallback() {
        #expect(
            AudioDeviceManager.resolveSelectedInputDeviceID(
                selectedUID: "razer",
                preferredDeviceID: nil,
                systemDefaultDeviceID: 2
            ) == nil
        )
    }

    @Test("The system-default and available explicit selections resolve normally")
    func resolvesAvailableSelections() {
        #expect(
            AudioDeviceManager.resolveSelectedInputDeviceID(
                selectedUID: AudioDevice.systemDefault.uid,
                preferredDeviceID: nil,
                systemDefaultDeviceID: 2
            ) == 2
        )
        #expect(
            AudioDeviceManager.resolveSelectedInputDeviceID(
                selectedUID: "razer",
                preferredDeviceID: 1,
                systemDefaultDeviceID: 2
            ) == 1
        )
    }

    @Test("The preferred microphone is restored when it becomes available")
    func restoresReconnectedPreference() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("razer", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(true, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 2)
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults
        )

        coordinator.reconcileNow()
        devices.devicesByUID["razer"] = 1
        devices.namesByID[1] = "Razer Seiren Mini"
        coordinator.reconcileNow()

        #expect(devices.defaultInputSetRequests == [1])
        #expect(devices.defaultInputID == 1)
        #expect(
            devices.announcements == [
                DeviceChangeAnnouncement(
                    deviceName: "Razer Seiren Mini",
                    transport: .usb,
                    phase: .ready
                )
            ]
        )
    }

    @Test("An available pinned microphone silently defeats an unrelated route steal")
    func restoresPinnedPreferenceSilently() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("preferred-mic", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(true, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 1)
        devices.devicesByUID["preferred-mic"] = 1
        devices.namesByID[1] = "Preferred Microphone"
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults
        )

        devices.defaultInputID = 2
        coordinator.reconcileNow()

        #expect(devices.defaultInputSetRequests == [1])
        #expect(devices.defaultInputID == 1)
        #expect(devices.announcements.isEmpty)
    }

    @Test("An unpinned explicit microphone does not change the system default")
    func unpinnedSelectionLeavesDefaultAlone() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("razer", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(false, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 2)
        devices.devicesByUID["razer"] = 1
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults
        )

        coordinator.reconcileNow()

        #expect(devices.defaultInputSetRequests.isEmpty)
        #expect(devices.defaultInputID == 2)
        #expect(defaults.string(forKey: Constants.StorageKeys.selectedMicrophone) == "razer")
        #expect(devices.announcements.isEmpty)
    }

    @Test("A transient Core Audio failure retries the primary microphone restore")
    func retriesFailedRestore() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("razer", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(true, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 2)
        devices.devicesByUID["razer"] = 1
        devices.setResults = [false, true]
        var scheduledWork: [DispatchWorkItem] = []
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults,
            scheduleWork: { _, workItem in scheduledWork.append(workItem) }
        )

        coordinator.reconcileNow(announceFinalDevice: false)
        #expect(devices.defaultInputSetRequests == [1])
        #expect(scheduledWork.count == 1)

        scheduledWork.removeFirst().perform()
        #expect(devices.defaultInputSetRequests == [1, 1])
        #expect(devices.defaultInputID == 1)
    }

    @Test("A Mirador session yields the route and restores the preferred microphone afterward")
    func externalSessionRestoresPreference() throws {
        let fixture = try makeDefaults()
        let defaults = fixture.defaults
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set("razer", forKey: Constants.StorageKeys.selectedMicrophone)
        defaults.set(true, forKey: Constants.StorageKeys.pinPrimaryMicrophone)

        let devices = FakePreferredMicrophoneDeviceManager(defaultInputID: 3)
        devices.devicesByUID["razer"] = 1
        var scheduledWork: [DispatchWorkItem] = []
        let coordinator = PreferredMicrophoneCoordinator(
            deviceManager: devices,
            userDefaults: defaults,
            scheduleWork: { _, workItem in scheduledWork.append(workItem) }
        )

        coordinator.beginExternalDefaultInputSession()
        coordinator.reconcileNow(announceFinalDevice: false)
        #expect(devices.defaultInputSetRequests.isEmpty)

        coordinator.endExternalDefaultInputSession()
        #expect(scheduledWork.count == 1)
        scheduledWork.removeFirst().perform()

        #expect(devices.defaultInputSetRequests == [1])
        #expect(devices.defaultInputID == 1)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PreferredMicrophoneCoordinatorTests.\(UUID())"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

@MainActor
private final class FakePreferredMicrophoneDeviceManager: PreferredMicrophoneDeviceManaging {
    let routeChangeSubject = PassthroughSubject<Void, Never>()
    var routeChanges: AnyPublisher<Void, Never> {
        routeChangeSubject.eraseToAnyPublisher()
    }

    var defaultInputID: AudioDeviceID?
    var devicesByUID: [String: AudioDeviceID] = [:]
    var namesByID: [AudioDeviceID: String] = [2: "AirPods"]
    var defaultInputSetRequests: [AudioDeviceID] = []
    var setResults: [Bool] = []
    var announcements: [DeviceChangeAnnouncement] = []

    init(defaultInputID: AudioDeviceID?) {
        self.defaultInputID = defaultInputID
    }

    func refreshDevices() {}

    func getSystemDefaultInputDevice() -> AudioDeviceID? {
        defaultInputID
    }

    func getDeviceID(for uid: String) -> AudioDeviceID? {
        devicesByUID[uid]
    }

    func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        namesByID[deviceID]
    }

    func transportType(for deviceID: AudioDeviceID) -> AudioDeviceTransport {
        deviceID == 1 ? .usb : .bluetooth
    }

    func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        defaultInputSetRequests.append(deviceID)
        let result = setResults.isEmpty ? true : setResults.removeFirst()
        if result {
            defaultInputID = deviceID
        }
        return result
    }

    func captureRouteSettleDelay() -> TimeInterval {
        0
    }

    func publishDeviceChange(_ announcement: DeviceChangeAnnouncement) {
        announcements.append(announcement)
    }
}
