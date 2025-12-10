//
//  AudioLevelMonitor.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import Foundation
import AVFoundation
import CoreAudio
import Combine

/// Monitor de nivel de audio en tiempo real para el micrófono
class AudioLevelMonitor: ObservableObject {
    
    static let shared = AudioLevelMonitor()
    
    private var audioEngine: AVAudioEngine?
    private var isMonitoring = false
    
    /// Nivel de audio actual (0.0 - 1.0)
    @Published var audioLevel: Float = 0.0
    
    /// Nivel pico reciente (para efecto visual)
    @Published var peakLevel: Float = 0.0
    
    /// Si el monitor está activo
    @Published var isActive = false
    
    /// Gain/boost de audio (1.0 = normal, 2.0 = 2x amplificación)
    @Published var gain: Float = 1.0
    
    /// Si hubo un error al iniciar el monitoreo
    @Published var hasError = false
    @Published var errorMessage: String?
    
    private var peakDecayTimer: Timer?
    private var previousDefaultDevice: AudioDeviceID?
    
    private init() {}
    
    /// Inicia el monitoreo del micrófono
    func startMonitoring(deviceUID: String = "default") {
        guard !isMonitoring else { return }
        
        // Reset error state
        hasError = false
        errorMessage = nil
        
        // Guardar el dispositivo default actual para restaurarlo después
        previousDefaultDevice = AudioDeviceManager.shared.getSystemDefaultInputDevice()
        
        // Configurar dispositivo si no es default
        if deviceUID != "default" {
            if let deviceID = AudioDeviceManager.shared.getDeviceID(for: deviceUID) {
                // Cambiar el dispositivo de entrada del sistema temporalmente
                let success = AudioDeviceManager.shared.setSystemDefaultInputDevice(deviceID)
                if !success {
                    print("⚠️ No se pudo cambiar al dispositivo seleccionado, usando default")
                }
            } else {
                print("⚠️ No se encontró el dispositivo: \(deviceUID)")
            }
        }
        
        // Pequeño delay para que el sistema aplique el cambio de dispositivo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startAudioEngine()
        }
    }
    
    /// Inicia el AVAudioEngine después de configurar el dispositivo
    private func startAudioEngine() {
        // Crear nuevo audio engine
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            setError("No se pudo crear el motor de audio")
            return
        }
        
        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            
            // Verificar que el formato sea válido
            guard format.sampleRate > 0 && format.channelCount > 0 else {
                setError("Formato de audio inválido")
                return
            }
            
            // Instalar tap para leer los niveles de audio
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            isMonitoring = true
            isActive = true
            
            // Timer para decay del pico
            peakDecayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if self.peakLevel > self.audioLevel {
                    self.peakLevel = max(self.audioLevel, self.peakLevel - 0.02)
                }
            }
            
            print("🎤 Monitoreo de nivel iniciado")
        } catch {
            setError("Error al iniciar: \(error.localizedDescription)")
            cleanup()
        }
    }
    
    /// Detiene el monitoreo
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        cleanup()
        
        // Restaurar el dispositivo default anterior si lo cambiamos
        if let previousDevice = previousDefaultDevice {
            AudioDeviceManager.shared.setSystemDefaultInputDevice(previousDevice)
            previousDefaultDevice = nil
        }
        
        isMonitoring = false
        isActive = false
        audioLevel = 0
        peakLevel = 0
        
        print("🎤 Monitoreo de nivel detenido")
    }
    
    /// Limpia recursos sin cambiar el estado de monitoreo
    private func cleanup() {
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
        
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        audioEngine = nil
    }
    
    /// Reinicia el monitoreo con un nuevo dispositivo
    func restartMonitoring(deviceUID: String) {
        stopMonitoring()
        
        // Delay para que el sistema libere el dispositivo
        let delay: Double = 0.3
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startMonitoring(deviceUID: deviceUID)
        }
    }
    
    /// Procesa el buffer de audio y extrae el nivel
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        guard buffer.frameLength > 0 else { return }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map {
            channelDataValue[$0]
        }
        
        guard !channelDataValueArray.isEmpty else { return }
        
        // Calcular RMS (Root Mean Square) para un nivel más suave
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(channelDataValueArray.count))
        
        // Aplicar gain
        let amplifiedRms = rms * gain
        
        // Convertir a escala logarítmica para mejor visualización
        let avgPower = 20 * log10(max(amplifiedRms, 0.0001)) // Evitar log(0)
        
        // Normalizar a 0-1 (asumiendo rango de -60dB a 0dB)
        let minDb: Float = -60
        let maxDb: Float = 0
        let normalizedLevel = max(0, min(1, (avgPower - minDb) / (maxDb - minDb)))
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Suavizar el nivel con interpolación
            self.audioLevel = self.audioLevel * 0.7 + normalizedLevel * 0.3
            
            // Actualizar pico si es mayor
            if normalizedLevel > self.peakLevel {
                self.peakLevel = normalizedLevel
            }
        }
    }
    
    /// Establece un error
    private func setError(_ message: String) {
        print("❌ AudioLevelMonitor: \(message)")
        hasError = true
        errorMessage = message
        isActive = false
    }
    
    deinit {
        stopMonitoring()
    }
}
