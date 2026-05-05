//
//  AudioDeviceManager.swift
//  SapoWhisper
//
//

import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog
import os

/// Representa un dispositivo de audio (micrófono)
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static let systemDefault = AudioDevice(id: 0, name: "Sistema (Por defecto)", uid: "default")

    /// Lista de patrones de nombres de dispositivos a filtrar (dispositivos virtuales del sistema)
    static let filteredPatterns = [
        "CADefaultDeviceAggregate",
        "CADefaultDevice",
        "Aggregate Device",
    ]

    /// Verifica si este dispositivo debe ser filtrado
    var shouldBeFiltered: Bool {
        AudioDevice.filteredPatterns.contains { name.contains($0) || uid.contains($0) }
    }
}

/// Maneja la lista de dispositivos de audio disponibles
class AudioDeviceManager: ObservableObject {

    static let shared = AudioDeviceManager()
    private static let recorderInputSettleWindow: CFTimeInterval = 0.35

    private struct StateSnapshot {
        var availableDevices: [AudioDevice] = [.systemDefault]
        var devicesByUID: [String: AudioDeviceID] = [:]
        var lastKnownDefaultInputDeviceID: AudioDeviceID?
        var lastKnownDefaultOutputDeviceID: AudioDeviceID?
        var lastDefaultInputTransitionTime: CFAbsoluteTime = 0
        var lastDefaultOutputTransitionTime: CFAbsoluteTime = 0
        var lastDeviceListChangeTime: CFAbsoluteTime = 0
        var suppressNextDefaultInputNotification = false
    }

    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceUID: String = "default"

    /// Name of the newly detected default input device (published when it changes)
    @Published var detectedDeviceName: String? = nil
    var routeChanges: AnyPublisher<Void, Never> {
        routeChangeSubject.eraseToAnyPublisher()
    }

    private let stateQueue = DispatchQueue(label: "com.sapowhisper.audioDevice.state", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "com.sapowhisper.audioDevice.listeners", qos: .userInitiated)
    private let routeChangeSubject = PassthroughSubject<Void, Never>()
    private var state = StateSnapshot()

    private init() {
        let initialDefaultInput = getSystemDefaultInputDevice()
        let initialDefaultOutput = getSystemDefaultOutputDevice()
        writeState { state in
            state.lastKnownDefaultInputDeviceID = initialDefaultInput
            state.lastKnownDefaultOutputDeviceID = initialDefaultOutput
        }
        refreshDevices()
        setupDeviceChangeListener()
        setupDefaultInputDeviceListener()
        setupDefaultOutputDeviceListener()
    }

    /// Refresca la lista de dispositivos de audio disponibles
    func refreshDevices() {
        let devices = loadAvailableInputDevices()
        updateAvailableDevicesSnapshot(devices)
        publishAvailableDevices(devices)
    }

    /// Obtiene información de un dispositivo de entrada
    private func loadAvailableInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = [.systemDefault]
        guard let deviceIDs = queryAllDeviceIDs() else {
            return devices
        }

        for deviceID in deviceIDs {
            if let device = getInputDevice(deviceID: deviceID) {
                // Filtrar dispositivos virtuales del sistema
                if !device.shouldBeFiltered {
                    devices.append(device)
                }
            }
        }

        return devices
    }

    private func getInputDevice(deviceID: AudioDeviceID) -> AudioDevice? {
        // Verificar si tiene canales de entrada
        var inputChannels: UInt32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)

        guard status == noErr else { return nil }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferList)

        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            inputChannels += buffer.mNumberChannels
        }

        guard inputChannels > 0 else { return nil }

        // Obtener nombre del dispositivo
        var namePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &namePropertyAddress, 0, nil, &nameSize, &name)

        guard status == noErr, let deviceName = name?.takeRetainedValue() as String? else { return nil }

        // Obtener UID del dispositivo
        var uidPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidPropertyAddress, 0, nil, &uidSize, &uid)

        guard status == noErr, let deviceUID = uid?.takeRetainedValue() as String? else { return nil }

        return AudioDevice(id: deviceID, name: deviceName, uid: deviceUID)
    }

    /// Configura un listener para cambios en dispositivos
    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.recordDeviceListChange()
            self?.refreshDevices()
            // Also check if default input changed (macOS sometimes only fires
            // the device list change, not the default input change)
            self?.checkDefaultInputDeviceChange()
            self?.checkDefaultOutputDeviceChange()
        }
    }

    /// Listens for changes to the system's default input device
    private func setupDefaultInputDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
    }

    /// Listens for changes to the system's default output device.
    private func setupDefaultOutputDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            listenerQueue
        ) { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
    }

    private func handleDefaultInputDeviceChanged() {
        // Skip if this change was triggered by our own setSystemDefaultInputDevice call
        let shouldSkip = writeState { state in
            if state.suppressNextDefaultInputNotification {
                state.suppressNextDefaultInputNotification = false
                return true
            }
            return false
        }

        if shouldSkip {
            return
        }

        refreshDevices()
        checkDefaultInputDeviceChange()
    }

    private func handleDefaultOutputDeviceChanged() {
        checkDefaultOutputDeviceChange()
    }

    /// Checks if the default input device actually changed and notifies if so
    private func checkDefaultInputDeviceChange() {
        guard let currentDeviceID = getSystemDefaultInputDevice() else { return }
        let timestamp = CFAbsoluteTimeGetCurrent()

        let changed = writeState { state in
            guard currentDeviceID != state.lastKnownDefaultInputDeviceID else { return false }
            state.lastKnownDefaultInputDeviceID = currentDeviceID
            state.lastDefaultInputTransitionTime = timestamp
            return true
        }

        guard changed else { return }

        let deviceName = getDeviceName(for: currentDeviceID) ?? "Unknown"
        print("🎙️ [audio route] default input -> \(deviceName)")
        SapoLog.audioRoute.info("Default input changed to \(deviceName, privacy: .public)")
        notifyRouteChange()
    }

    private func checkDefaultOutputDeviceChange() {
        guard let currentDeviceID = getSystemDefaultOutputDevice() else { return }
        let timestamp = CFAbsoluteTimeGetCurrent()

        let changed = writeState { state in
            guard currentDeviceID != state.lastKnownDefaultOutputDeviceID else { return false }
            state.lastKnownDefaultOutputDeviceID = currentDeviceID
            state.lastDefaultOutputTransitionTime = timestamp
            return true
        }

        guard changed else { return }

        let deviceName = getDeviceName(for: currentDeviceID) ?? "Unknown"
        print("🔊 [audio route] default output -> \(deviceName)")
        SapoLog.audioRoute.info("Default output changed to \(deviceName, privacy: .public)")
        notifyRouteChange()
    }

    func recorderInputSettleDelay() -> TimeInterval {
        captureRouteSettleDelay()
    }

    /// Gets the name of a device by its ID
    func getDeviceName(for deviceID: AudioDeviceID) -> String? {
        if let cachedName = readState({ state in
            state.availableDevices.first(where: { $0.id == deviceID })?.name
        }) {
            return cachedName
        }

        return queryDeviceName(deviceID)
    }

    /// Obtiene el AudioDeviceID para un UID dado
    func getDeviceID(for uid: String) -> AudioDeviceID? {
        if uid == "default" {
            return getSystemDefaultInputDevice()
        }

        return readState { state in
            state.devicesByUID[uid]
        }
    }

    /// Obtiene el dispositivo de entrada por defecto del sistema
    func getSystemDefaultInputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    /// Obtiene el dispositivo de salida por defecto del sistema
    func getSystemDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    /// Configura temporalmente un dispositivo como entrada por defecto del sistema
    /// Retorna true si tuvo éxito
    @discardableResult
    func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return false
        }

        if let currentDeviceID = getSystemDefaultInputDevice(), currentDeviceID == deviceID {
            return true
        }

        var deviceIDValue = deviceID
        var namePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &namePropertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDValue
        )

        if status == noErr {
            let timestamp = CFAbsoluteTimeGetCurrent()
            writeState { state in
                state.suppressNextDefaultInputNotification = true
                state.lastKnownDefaultInputDeviceID = deviceID
                state.lastDefaultInputTransitionTime = timestamp
            }
            return true
        } else {
            return false
        }
    }

    func captureRouteSettleDelay() -> TimeInterval {
        let latestTransition = readState { state in
            max(state.lastDefaultInputTransitionTime, max(state.lastDefaultOutputTransitionTime, state.lastDeviceListChangeTime))
        }

        guard latestTransition > 0 else { return 0 }
        let elapsed = CFAbsoluteTimeGetCurrent() - latestTransition
        return max(0, Self.recorderInputSettleWindow - elapsed)
    }

    /// Settle delay accounting for any device transition (list change OR default input change).
    /// Use this for specific device UIDs; `recorderInputSettleDelay` only tracks default input changes.
    func deviceTransitionSettleDelay() -> TimeInterval {
        captureRouteSettleDelay()
    }

    private func updateAvailableDevicesSnapshot(_ devices: [AudioDevice]) {
        writeState { state in
            state.availableDevices = devices
            state.devicesByUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0.id) })
        }
    }

    private func publishAvailableDevices(_ devices: [AudioDevice]) {
        if Thread.isMainThread {
            availableDevices = devices
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.availableDevices = devices
            }
        }
    }

    private func recordDeviceListChange() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        writeState { state in
            state.lastDeviceListChangeTime = timestamp
        }
        SapoLog.audioRoute.info("Audio device list changed")
        notifyRouteChange()
    }

    func publishDetectedDeviceName(_ deviceName: String) {
        let publish = {
            self.detectedDeviceName = nil
            self.detectedDeviceName = deviceName
        }

        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    private func queryAllDeviceIDs() -> [AudioDeviceID]? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        )
        guard sizeStatus == noErr else {
            print("❌ Error obteniendo tamaño de dispositivos: \(sizeStatus)")
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else {
            print("❌ Error obteniendo dispositivos: \(status)")
            return nil
        }

        return deviceIDs
    }

    private func queryDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var namePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &namePropertyAddress, 0, nil, &nameSize, &name)

        guard status == noErr, let deviceName = name?.takeRetainedValue() as String? else { return nil }
        return deviceName
    }

    private func readState<T>(_ block: (StateSnapshot) -> T) -> T {
        stateQueue.sync {
            block(state)
        }
    }

    @discardableResult
    private func writeState<T>(_ block: (inout StateSnapshot) -> T) -> T {
        stateQueue.sync {
            block(&state)
        }
    }

    private func notifyRouteChange() {
        DispatchQueue.main.async { [weak self] in
            self?.routeChangeSubject.send()
        }
    }
}
