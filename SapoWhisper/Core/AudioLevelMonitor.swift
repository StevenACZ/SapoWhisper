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
    
    private var peakDecayTimer: Timer?
    
    private init() {}
    
    /// Inicia el monitoreo del micrófono
    func startMonitoring(deviceUID: String = "default") {
        guard !isMonitoring else { return }
        
        // Configurar dispositivo si no es default
        if deviceUID != "default" {
            configureInputDevice(deviceUID: deviceUID)
        }
        
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            print("❌ No se pudo crear el audio engine para monitoreo")
            return
        }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // Instalar tap para leer los niveles de audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        
        do {
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
            print("❌ Error iniciando monitoreo: \(error)")
        }
    }
    
    /// Detiene el monitoreo
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        peakDecayTimer?.invalidate()
        peakDecayTimer = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        isMonitoring = false
        isActive = false
        audioLevel = 0
        peakLevel = 0
        
        print("🎤 Monitoreo de nivel detenido")
    }
    
    /// Reinicia el monitoreo con un nuevo dispositivo
    func restartMonitoring(deviceUID: String) {
        stopMonitoring()
        
        // Pequeño delay para que el sistema libere el dispositivo
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.startMonitoring(deviceUID: deviceUID)
        }
    }
    
    /// Procesa el buffer de audio y extrae el nivel
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map {
            channelDataValue[$0]
        }
        
        // Calcular RMS (Root Mean Square) para un nivel más suave
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(channelDataValueArray.count))
        
        // Convertir a escala logarítmica para mejor visualización
        let avgPower = 20 * log10(rms)
        
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
    
    /// Configura el dispositivo de entrada
    private func configureInputDevice(deviceUID: String) {
        guard let deviceID = AudioDeviceManager.shared.getDeviceID(for: deviceUID) else {
            return
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
        
        if status != noErr {
            print("⚠️ Error configurando dispositivo para monitoreo: \(status)")
        }
    }
    
    deinit {
        stopMonitoring()
    }
}
