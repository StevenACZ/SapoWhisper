//
//  AudioEqualizerView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Vista de ecualizador de audio con barras animadas
/// Muestra el nivel de audio en tiempo real como barras verticales
struct AudioEqualizerView: View {

    let audioLevel: Float

    // Configuracion
    private let barCount = 17
    private let barWidth: CGFloat = 6
    private let barSpacing: CGFloat = 3
    private let maxBarHeight: CGFloat = 50
    private let minBarHeight: CGFloat = 4

    // Estado interno para las barras
    @State private var barHeights: [CGFloat] = []
    @State private var previousLevel: Float = 0

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                BarView(
                    height: barHeights.isEmpty ? minBarHeight : barHeights[index],
                    maxHeight: maxBarHeight,
                    index: index,
                    barCount: barCount
                )
                .frame(width: barWidth)
            }
        }
        .onAppear {
            initializeBars()
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
            let centerWeight = 1.0 - abs(position - 0.5) * 1.5 // Mas alto en el centro

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
}

// MARK: - Bar View

private struct BarView: View {
    let height: CGFloat
    let maxHeight: CGFloat
    let index: Int
    let barCount: Int

    var body: some View {
        VStack {
            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: 2)
                .fill(barGradient)
                .frame(height: height)
        }
        .frame(height: maxHeight)
    }

    private var barGradient: LinearGradient {
        let normalizedHeight = height / maxHeight

        // Colores segun nivel
        let colors: [Color]
        if normalizedHeight > 0.85 {
            // Muy alto - rojo
            colors = [.red, .orange]
        } else if normalizedHeight > 0.6 {
            // Alto - amarillo/naranja
            colors = [.orange, .yellow]
        } else if normalizedHeight > 0.35 {
            // Medio - amarillo/verde
            colors = [.yellow, .sapoGreen]
        } else {
            // Bajo - verde
            colors = [.sapoGreen, .sapoGreenLight]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

