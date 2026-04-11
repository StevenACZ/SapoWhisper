//
//  AutoDuckingManager.swift
//  SapoWhisper
//
//  Created by Steven on 11/04/26.
//

import Foundation
import CoreAudio
import AudioToolbox

/// Gestiona el Auto-Ducking: reduce el volumen del sistema durante la grabación
/// y lo restaura al terminar.
///
/// Usa Core Audio HAL APIs directamente ya que macOS no tiene
/// AVAudioSession.setCategory(.duckOthers) como iOS.
final class AutoDuckingManager {

    static let shared = AutoDuckingManager()

    // MARK: - State

    /// Si el sistema está actualmente ducked
    private(set) var isDucked = false

    /// Volumen original guardado antes de duckear
    private var originalVolume: Float?

    /// Device ID del output al que se le aplicó duck
    private var duckedDeviceID: AudioDeviceID?

    /// Serial queue para operaciones thread-safe
    private let queue = DispatchQueue(label: "com.sapowhisper.autoducking", qos: .userInteractive)

    // MARK: - Settings (read from UserDefaults)

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.autoDuckingEnabled)
    }

    /// Porcentaje de reducción (0.0 = sin reducción, 1.0 = silenciar completamente)
    /// Default: 0.5 (reduce al 50% del volumen original)
    private var duckAmount: Double {
        let amount = UserDefaults.standard.double(forKey: Constants.StorageKeys.autoDuckingAmount)
        // Si nunca se configuró (0.0), usar default 0.5
        return amount > 0 ? amount : 0.8
    }

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Maneja cambios de estado de la app para duck/restore automáticamente.
    /// Llamar desde el $appState sink del ViewModel.
    func handleStateChange(_ state: AppState) {
        switch state {
        case .recording:
            duck()
        case .processing:
            // Restaurar volumen al transcribir — el mic ya no está activo,
            // y la transcripción puede tardar 3-30s. Que el usuario siga
            // escuchando su música mientras espera.
            restore()
        case .idle:
            restore()
        case .error:
            restore()
        case .noModel:
            restore()
        }
    }

    /// Reduce el volumen del sistema al nivel configurado
    func duck() {
        queue.async { [weak self] in
            self?._duck()
        }
    }

    /// Restaura el volumen del sistema al nivel original
    func restore() {
        queue.async { [weak self] in
            self?._restore()
        }
    }

    /// Restaura forzosamente sin verificar isEnabled (para app termination)
    func forceRestore() {
        queue.sync { [weak self] in
            self?._restore()
        }
    }

    // MARK: - Core Audio Implementation

    private func _duck() {
        guard isEnabled, !isDucked else { return }

        guard let deviceID = getSystemDefaultOutputDevice() else {
            print("⚠️ [auto-ducking] No se encontró dispositivo de salida")
            return
        }

        guard let currentVolume = getDeviceVolume(deviceID: deviceID) else {
            print("⚠️ [auto-ducking] No se pudo leer el volumen actual")
            return
        }

        // Guardar estado original
        originalVolume = currentVolume
        duckedDeviceID = deviceID

        // Calcular volumen reducido: original × (1 - duckAmount)
        // duckAmount=0.5 → volumen baja al 50%
        // duckAmount=0.8 → volumen baja al 20%
        let reducedVolume = currentVolume * Float(1.0 - duckAmount)
        let clampedVolume = max(0.0, min(1.0, reducedVolume))

        if setDeviceVolume(deviceID: deviceID, volume: clampedVolume) {
            isDucked = true
            print("🔉 [auto-ducking] Volumen reducido: \(Int(currentVolume * 100))% → \(Int(clampedVolume * 100))% (duck: \(Int(duckAmount * 100))%)")
        }
    }

    private func _restore() {
        guard isDucked,
              let original = originalVolume,
              let deviceID = duckedDeviceID else {
            return
        }

        // Verificar si el usuario cambió el volumen manualmente durante la grabación.
        // Si el volumen actual es diferente al que nosotros pusimos, el usuario lo
        // cambió — respetar su decisión y no sobrescribir.
        if let currentVolume = getDeviceVolume(deviceID: deviceID) {
            let expectedDuckedVolume = original * Float(1.0 - duckAmount)
            let tolerance: Float = 0.02 // ~2% de tolerancia

            if abs(currentVolume - expectedDuckedVolume) > tolerance {
                print("🔊 [auto-ducking] Usuario cambió volumen durante grabación (\(Int(currentVolume * 100))%), respetando su elección")
                isDucked = false
                originalVolume = nil
                duckedDeviceID = nil
                return
            }
        }

        if setDeviceVolume(deviceID: deviceID, volume: original) {
            print("🔊 [auto-ducking] Volumen restaurado: \(Int(original * 100))%")
        }

        isDucked = false
        originalVolume = nil
        duckedDeviceID = nil
    }

    // MARK: - Core Audio Helpers

    /// Obtiene el AudioDeviceID del dispositivo de salida por defecto del sistema
    private func getSystemDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    /// Lee el volumen actual de un dispositivo de salida (0.0 - 1.0)
    private func getDeviceVolume(deviceID: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        // Intentar primero con VirtualMainVolume (volumen maestro virtual)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Verificar si la propiedad existe
        if AudioObjectHasProperty(deviceID, &address) {
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            if status == noErr {
                return volume
            }
        }

        // Fallback: intentar con volumen del canal 1 (master)
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mElement = 1 // Canal izquierdo / master

        if AudioObjectHasProperty(deviceID, &address) {
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            if status == noErr {
                return volume
            }
        }

        return nil
    }

    /// Establece el volumen de un dispositivo de salida (0.0 - 1.0)
    @discardableResult
    private func setDeviceVolume(deviceID: AudioDeviceID, volume: Float) -> Bool {
        var vol = max(0.0, min(1.0, volume))

        // Intentar primero con VirtualMainVolume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(deviceID, &address) {
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &vol
            )
            if status == noErr {
                return true
            }
        }

        // Fallback: setear ambos canales por separado
        address.mSelector = kAudioDevicePropertyVolumeScalar
        var success = false

        for channel: UInt32 in [1, 2] { // Canal izquierdo y derecho
            address.mElement = channel
            if AudioObjectHasProperty(deviceID, &address) {
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &vol
                )
                if status == noErr {
                    success = true
                }
            }
        }

        return success
    }
}
