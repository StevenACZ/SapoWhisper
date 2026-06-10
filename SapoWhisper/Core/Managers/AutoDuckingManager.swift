//
//  AutoDuckingManager.swift
//  SapoWhisper
//
//

import AudioToolbox
import CoreAudio
import Foundation
import os

/// Gestiona el Auto-Ducking: reduce el volumen del sistema durante la grabación
/// y lo restaura al terminar.
///
/// Usa Core Audio HAL APIs directamente ya que macOS no tiene
/// AVAudioSession.setCategory(.duckOthers) como iOS.
///
/// Concurrency: nonisolated by design — all state is confined to the serial
/// ducking queue; public methods only dispatch onto it.
nonisolated final class AutoDuckingManager: @unchecked Sendable {

    static let shared = AutoDuckingManager()

    // MARK: - State

    /// Si el sistema está actualmente ducked
    private(set) var isDucked = false

    /// Volumen original guardado antes de duckear
    private var originalVolume: Float?

    /// Device ID del output al que se le aplicó duck
    private var duckedDeviceID: AudioDeviceID?

    /// Duck programado (espera a que termine el beep de inicio antes de bajar el volumen)
    private var pendingDuckItem: DispatchWorkItem?

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
            // El beep de inicio debe sonar al volumen original: duckear de
            // inmediato lo atenuaba (su cuerpo audible dura ~150 ms).
            duck(afterDelay: startSoundGrace())
        case .processing, .polishing:
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
    func duck(afterDelay delay: TimeInterval = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingDuckItem?.cancel()
            self.pendingDuckItem = nil

            guard delay > 0 else {
                self._duck()
                return
            }

            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingDuckItem = nil
                self._duck()
            }
            self.pendingDuckItem = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// Restaura el volumen del sistema al nivel original
    func restore() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingDuckItem?.cancel()
            self.pendingDuckItem = nil
            self._restore()
        }
    }

    /// Restaura forzosamente sin verificar isEnabled (para app termination)
    func forceRestore() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.pendingDuckItem?.cancel()
            self.pendingDuckItem = nil
            self._restore()
        }
    }

    /// Retraso del duck mientras suena el beep de inicio; 0 si está apagado.
    private func startSoundGrace() -> TimeInterval {
        let defaults = UserDefaults.standard
        let soundEnabled =
            defaults.object(forKey: Constants.StorageKeys.playSound) == nil
            || defaults.bool(forKey: Constants.StorageKeys.playSound)
        return soundEnabled ? 0.35 : 0
    }

    // MARK: - Core Audio Implementation

    private func _duck() {
        guard isEnabled, !isDucked else { return }

        guard let deviceID = getSystemDefaultOutputDevice() else {
            SapoLog.audioRoute.warning("Auto-ducking: no output device found")
            return
        }

        guard let currentVolume = getDeviceVolume(deviceID: deviceID) else {
            SapoLog.audioRoute.warning("Auto-ducking: cannot read current volume")
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
            SapoLog.audioRoute.info(
                "Auto-ducking applied from=\(Int(currentVolume * 100), privacy: .public)% to=\(Int(clampedVolume * 100), privacy: .public)% amount=\(Int(self.duckAmount * 100), privacy: .public)%"
            )
        }
    }

    private func _restore() {
        guard isDucked,
            let original = originalVolume,
            let deviceID = duckedDeviceID
        else {
            return
        }

        // A7: always restore the saved volume. The old "respect a user volume
        // change" heuristic compared against quantized Bluetooth volumes and
        // could leave audio ducked forever — the duck is temporary by design.
        if setDeviceVolume(deviceID: deviceID, volume: original) {
            SapoLog.audioRoute.info(
                "Auto-ducking restored volume=\(Int(original * 100), privacy: .public)%"
            )
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
        address.mElement = 1  // Canal izquierdo / master

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

        for channel: UInt32 in [1, 2] {  // Canal izquierdo y derecho
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
