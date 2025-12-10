//
//  TranscribingIndicator.swift
//  SapoWhisper
//

import SwiftUI

/// Indicador de carga durante la transcripcion
/// Muestra dots animados que se mueven en secuencia
struct TranscribingIndicator: View {

    @State private var animatingDots: [Bool] = [false, false, false]

    private let dotSize: CGFloat = 10
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.processing)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(animatingDots[index] ? 1.3 : 0.8)
                    .opacity(animatingDots[index] ? 1.0 : 0.4)
            }
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        for i in 0..<3 {
            let delay = Double(i) * 0.2
            withAnimation(
                .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
                .delay(delay)
            ) {
                animatingDots[i] = true
            }
        }
    }
}
