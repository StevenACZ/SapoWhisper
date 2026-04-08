//
//  AudioDeviceManager.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import Foundation
import AVFoundation
import CoreAudio
import Combine

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
        "Aggregate Device"
    ]
    
    /// Verifica si este dispositivo debe ser filtrado
    var shouldBeFiltered: Bool {
        AudioDevice.filteredPatterns.contains { name.contains($0) || uid.contains($0) }
    }
}

/// Maneja la lista de dispositivos de audio disponibles
class AudioDeviceManager: ObservableObject {

    static let shared = AudioDeviceManager()

    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceUID: String = "default"

    /// Name of the newly detected default input device (published when it changes)
    @Published var detectedDeviceName: String? = nil

    /// Tracks the last known default input device ID to detect actual changes
    private var lastKnownDefaultInputDeviceID: AudioDeviceID?

    private init() {
        // Capture initial default device ID without triggering notification
        lastKnownDefaultInputDeviceID = getSystemDefaultInputDevice()
        refreshDevices()
        setupDeviceChangeListener()
        setupDefaultInputDeviceListener()
    }

    /// Refresca la lista de dispositivos de audio disponibles
    func refreshDevices() {
        var devices: [AudioDevice] = [.systemDefault]

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            print("❌ Error obteniendo tamaño de dispositivos: \(status)")
            availableDevices = devices
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            print("❌ Error obteniendo dispositivos: \(status)")
            availableDevices = devices
            return
        }

        for deviceID in deviceIDs {
            if let device = getInputDevice(deviceID: deviceID) {
                // Filtrar dispositivos virtuales del sistema
                if !device.shouldBeFiltered {
                    devices.append(device)
                }
            }
        }

        availableDevices = devices
        print("🎤 Dispositivos de entrada encontrados: \(devices.count - 1)") // -1 por System Default
    }

    /// Obtiene información de un dispositivo de entrada
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
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
            // Also check if default input changed (macOS sometimes only fires
            // the device list change, not the default input change)
            self?.checkDefaultInputDeviceChange()
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
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
    }

    private func handleDefaultInputDeviceChanged() {
        refreshDevices()
        checkDefaultInputDeviceChange()
    }

    /// Checks if the default input device actually changed and notifies if so
    private func checkDefaultInputDeviceChange() {
        guard let currentDeviceID = getSystemDefaultInputDevice() else { return }

        // Only notify if the device actually changed
        if currentDeviceID != lastKnownDefaultInputDeviceID {
            lastKnownDefaultInputDeviceID = currentDeviceID
            let deviceName = getDeviceName(for: currentDeviceID) ?? "Unknown"
            // Force a new publish by setting to nil first, then the name
            detectedDeviceName = nil
            detectedDeviceName = deviceName
            print("🔄 Default input device changed to: \(deviceName)")
        }
    }

    /// Gets the name of a device by its ID
    func getDeviceName(for deviceID: AudioDeviceID) -> String? {
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

    /// Obtiene el AudioDeviceID para un UID dado
    func getDeviceID(for uid: String) -> AudioDeviceID? {
        if uid == "default" {
            return getSystemDefaultInputDevice()
        }
        return availableDevices.first(where: { $0.uid == uid })?.id
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
    
    /// Configura temporalmente un dispositivo como entrada por defecto del sistema
    /// Retorna true si tuvo éxito
    @discardableResult
    func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            print("⚠️ Ignorando cambio a dispositivo de entrada invalido (0)")
            return false
        }

        if let currentDeviceID = getSystemDefaultInputDevice(), currentDeviceID == deviceID {
            print("⏱️ [audio device] set default skipped (already active)")
            return true
        }

        var deviceIDValue = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDValue
        )
        
        if status == noErr {
            print("✅ Dispositivo de entrada del sistema cambiado")
            return true
        } else {
            print("⚠️ Error cambiando dispositivo del sistema: \(status)")
            return false
        }
    }
}
