//
//  AudioLevelMeter.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

/// Componente visual de medidor de nivel de audio con barras animadas
struct AudioLevelMeter: View {
    @ObservedObject var monitor: AudioLevelMonitor
    
    /// Número de barras en el medidor
    let barCount: Int
    
    /// Altura del medidor
    let height: CGFloat
    
    init(monitor: AudioLevelMonitor = .shared, barCount: Int = 20, height: CGFloat = 20) {
        self.monitor = monitor
        self.barCount = barCount
        self.height = height
    }
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    AudioBar(
                        isActive: isBarActive(index: index),
                        isPeak: isBarPeak(index: index),
                        color: barColor(index: index)
                    )
                }
            }
        }
        .frame(height: height)
    }
    
    /// Determina si una barra debe estar activa basado en el nivel actual
    private func isBarActive(index: Int) -> Bool {
        let threshold = Float(index) / Float(barCount)
        return monitor.audioLevel >= threshold
    }
    
    /// Determina si una barra es el pico actual
    private func isBarPeak(index: Int) -> Bool {
        let threshold = Float(index) / Float(barCount)
        let nextThreshold = Float(index + 1) / Float(barCount)
        return monitor.peakLevel >= threshold && monitor.peakLevel < nextThreshold
    }
    
    /// Color de la barra basado en su posición (verde -> amarillo -> rojo)
    private func barColor(index: Int) -> Color {
        let position = Float(index) / Float(barCount)
        
        if position < 0.6 {
            return .sapoGreen
        } else if position < 0.85 {
            return .yellow
        } else {
            return .red
        }
    }
}

/// Barra individual del medidor
struct AudioBar: View {
    let isActive: Bool
    let isPeak: Bool
    let color: Color
    
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barFill)
            .animation(.easeOut(duration: 0.05), value: isActive)
    }
    
    private var barFill: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(color)
        } else if isPeak {
            return AnyShapeStyle(color.opacity(0.8))
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.2))
        }
    }
}

/// Vista completa del medidor con controles
struct AudioLevelMeterView: View {
    @StateObject private var monitor = AudioLevelMonitor.shared
    let deviceUID: String
    
    @State private var isEnabled = false
    @State private var gain: Double = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Toggle para activar/desactivar
            HStack {
                Toggle(isOn: $isEnabled) {
                    Text("settings.test_microphone".localized)
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Spacer()
                
                if isEnabled && monitor.isActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("settings.listening".localized)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Mostrar meter y controles solo cuando está habilitado
            if isEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    // Error message si hay error
                    if monitor.hasError, let error = monitor.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }
                    
                    // Meter con porcentaje
                    HStack(spacing: 8) {
                        AudioLevelMeter(monitor: monitor)
                        
                        Text("\(Int(monitor.audioLevel * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                    
                    // Gain slider
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.1")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Slider(value: $gain, in: 0.5...3.0, step: 0.1)
                            .controlSize(.small)
                            .onChange(of: gain) { _, newValue in
                                monitor.gain = Float(newValue)
                            }
                        
                        Image(systemName: "speaker.wave.3")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("\(String(format: "%.1f", gain))x")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                    
                    Text("settings.gain_desc".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .onChange(of: isEnabled) { _, newValue in
            if newValue {
                monitor.gain = Float(gain)
                monitor.restartMonitoring(deviceUID: deviceUID)
            } else {
                monitor.stopMonitoring()
            }
        }
        .onChange(of: deviceUID) { _, newUID in
            if isEnabled {
                monitor.restartMonitoring(deviceUID: newUID)
            }
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AudioLevelMeterView(deviceUID: "default")
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
    }
    .padding()
    .frame(width: 400)
}
