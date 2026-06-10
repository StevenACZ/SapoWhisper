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

    /// Volumen original guardado antes de duckear; se conserva hasta que la
    /// rampa de restauración termina, por si un duck la interrumpe.
    private var originalVolume: Float?

    /// Device ID del output al que se le aplicó duck
    private var duckedDeviceID: AudioDeviceID?

    /// Invalida las rampas en curso cuando empieza una nueva
    private var fadeGeneration: UInt64 = 0

    /// Serial queue para operaciones thread-safe
    private let queue = DispatchQueue(label: "com.sapowhisper.autoducking", qos: .userInteractive)

    // MARK: - Fade tuning

    /// La bajada empieza al instante y dura lo justo para sentirse suave sin
    /// tapar el beep de inicio (~150 ms audibles al comienzo de la rampa).
    private static let duckFadeDuration: TimeInterval = 0.40
    private static let restoreFadeDuration: TimeInterval = 0.25
    private static let fadeStepInterval: TimeInterval = 0.02

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

    /// Reduce el volumen del sistema al nivel configurado con una rampa suave
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

    /// Restaura forzosamente sin rampa ni verificar isEnabled (para app termination)
    func forceRestore() {
        queue.sync { [weak self] in
            guard let self else { return }
            self.fadeGeneration &+= 1
            if let original = self.originalVolume, let deviceID = self.duckedDeviceID {
                self.setDeviceVolume(deviceID: deviceID, volume: original)
                SapoLog.audioRoute.info(
                    "Auto-ducking force-restored volume=\(Int(original * 100), privacy: .public)%"
                )
            }
            self.isDucked = false
            self.originalVolume = nil
            self.duckedDeviceID = nil
        }
    }

    // MARK: - Core Audio Implementation

    private func _duck() {
        guard isEnabled, !isDucked else { return }

        guard let deviceID = duckedDeviceID ?? getSystemDefaultOutputDevice() else {
            SapoLog.audioRoute.warning("Auto-ducking: no output device found")
            return
        }

        guard let currentVolume = getDeviceVolume(deviceID: deviceID) else {
            SapoLog.audioRoute.warning("Auto-ducking: cannot read current volume")
            return
        }

        // Si una restauración seguía en rampa, el volumen actual es parcial:
        // el original verdadero es el que esa rampa estaba devolviendo.
        let baseline = originalVolume ?? currentVolume
        originalVolume = baseline
        duckedDeviceID = deviceID
        isDucked = true

        // Calcular volumen reducido: original × (1 - duckAmount)
        // duckAmount=0.5 → volumen baja al 50%
        // duckAmount=0.8 → volumen baja al 20%
        let reducedVolume = baseline * Float(1.0 - duckAmount)
        let clampedVolume = max(0.0, min(1.0, reducedVolume))

        fade(deviceID: deviceID, from: currentVolume, to: clampedVolume, duration: Self.duckFadeDuration)
        SapoLog.audioRoute.info(
            "Auto-ducking fading from=\(Int(currentVolume * 100), privacy: .public)% to=\(Int(clampedVolume * 100), privacy: .public)% amount=\(Int(self.duckAmount * 100), privacy: .public)% durationMs=\(Int(Self.duckFadeDuration * 1000), privacy: .public)"
        )
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
        isDucked = false
        let currentVolume = getDeviceVolume(deviceID: deviceID) ?? original
        fade(deviceID: deviceID, from: currentVolume, to: original, duration: Self.restoreFadeDuration) {
            [weak self] in
            guard let self else { return }
            self.originalVolume = nil
            self.duckedDeviceID = nil
        }
        SapoLog.audioRoute.info(
            "Auto-ducking restoring volume=\(Int(original * 100), privacy: .public)%"
        )
    }

    /// Rampa de volumen por pasos en la cola serial. `onCompleted` solo corre
    /// si la rampa llega al final sin que otra la invalide.
    private func fade(
        deviceID: AudioDeviceID,
        from: Float,
        to: Float,
        duration: TimeInterval,
        onCompleted: (@Sendable () -> Void)? = nil
    ) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        let stepCount = max(1, Int(duration / Self.fadeStepInterval))

        for step in 1...stepCount {
            queue.asyncAfter(deadline: .now() + Self.fadeStepInterval * Double(step)) { [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                let progress = Float(step) / Float(stepCount)
                // smoothstep: arranca y termina sin escalones audibles
                let eased = progress * progress * (3 - 2 * progress)
                self.setDeviceVolume(deviceID: deviceID, volume: from + (to - from) * eased)
                if step == stepCount {
                    onCompleted?()
                }
            }
        }
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
