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
}

/// Maneja la lista de dispositivos de audio disponibles
class AudioDeviceManager: ObservableObject {

    static let shared = AudioDeviceManager()

    @Published var availableDevices: [AudioDevice] = []
    @Published var selectedDeviceUID: String = "default"

    private init() {
        refreshDevices()
        setupDeviceChangeListener()
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
                devices.append(device)
            }
        }

        availableDevices = devices
        print("🎤 Dispositivos de entrada encontrados: \(devices.count)")
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
        // Usamos &name y dejamos que Swift maneje el pointer, casteando a RawPointer
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
        }
    }

    /// Obtiene el AudioDeviceID para un UID dado
    func getDeviceID(for uid: String) -> AudioDeviceID? {
        if uid == "default" {
            return nil // Usar dispositivo por defecto del sistema
        }
        return availableDevices.first(where: { $0.uid == uid })?.id
    }
}
