//
//  AudioEqualizerView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Vista de ecualizador de audio con barras animadas centradas verticalmente
/// Estilo waveform compacto para layout horizontal en pill
struct AudioEqualizerView: View {

    let audioLevel: Float

    // Configuracion
    private let barCount: Int
    private let barWidth: CGFloat
    private let barSpacing: CGFloat = 2
    private let maxBarHeight: CGFloat = 28
    private let minBarHeight: CGFloat = 3

    init(audioLevel: Float, barCount: Int = 24, barWidth: CGFloat = 3) {
        self.audioLevel = audioLevel
        self.barCount = barCount
        self.barWidth = barWidth
    }

    // Estado interno para las barras
    @State private var barHeights: [CGFloat] = []
    @State private var previousLevel: Float = 0

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(for: index))
                    .frame(width: barWidth, height: barHeights.isEmpty ? minBarHeight : barHeights[index])
            }
        }
        .frame(height: maxBarHeight)
        .onAppear {
            initializeBars()
            if audioLevel > 0 {
                updateBars(with: audioLevel)
            }
        }
        .onChange(of: audioLevel) { oldValue, newValue in
            updateBars(with: newValue)
        }
    }

    // MARK: - Private Methods

    private func initializeBars() {
        barHeights = Array(repeating: minBarHeight, count: barCount)
    }

    private func updateBars(with level: Float) {
        // Interpolar suavemente
        let smoothedLevel = previousLevel * 0.3 + level * 0.7
        previousLevel = smoothedLevel

        // Generar alturas con variacion natural
        var newHeights: [CGFloat] = []

        for i in 0..<barCount {
            // Patron de onda sinusoidal para efecto visual
            let position = Double(i) / Double(barCount - 1)
            let centerWeight = 1.0 - abs(position - 0.5) * 1.5

            // Base del nivel de audio
            let baseHeight = CGFloat(smoothedLevel) * maxBarHeight * CGFloat(centerWeight)

            // Agregar variacion aleatoria para naturalidad
            let randomVariation = CGFloat.random(in: 0.7...1.3)
            let targetHeight = max(minBarHeight, baseHeight * randomVariation)

            // Interpolar con el valor anterior para suavizar
            let currentHeight = barHeights.isEmpty ? minBarHeight : barHeights[i]
            let newHeight = currentHeight * 0.4 + targetHeight * 0.6

            newHeights.append(min(maxBarHeight, max(minBarHeight, newHeight)))
        }

        withAnimation(.easeOut(duration: 0.05)) {
            barHeights = newHeights
        }
    }

    private func barColor(for index: Int) -> Color {
        guard !barHeights.isEmpty else { return .primary.opacity(0.4) }

        let normalizedHeight = barHeights[index] / maxBarHeight

        if normalizedHeight > 0.85 {
            return .red.opacity(0.9)
        } else if normalizedHeight > 0.6 {
            return .orange.opacity(0.8)
        } else if normalizedHeight > 0.35 {
            return .sapoGreen.opacity(0.8)
        } else {
            return .primary.opacity(0.4)
        }
    }
}

#Preview("Equalizer Levels") {
    VStack(spacing: 16) {
        ForEach([(0, "Idle"), (0.2, "Low"), (0.5, "Medium"), (0.8, "High")] as [(Float, String)], id: \.1) { level, label in
            HStack(spacing: 12) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
                AudioEqualizerView(audioLevel: level)
                    .frame(width: 120, height: 28)
            }
        }

        Divider().padding(.horizontal)

        VStack(spacing: 6) {
            Text("Compact (Streaming)")
                .font(.caption2)
                .foregroundColor(.secondary)
            AudioEqualizerView(audioLevel: 0.5, barCount: 8, barWidth: 4)
                .frame(width: 46, height: 22)
        }
    }
    .padding(20)
}
