//
//  TranscribingIndicator.swift
//  SapoWhisper
//

import SwiftUI

/// Indicador de carga durante la transcripcion
/// Muestra dots animados que se mueven en secuencia
struct TranscribingIndicator: View {
    var color: Color = .processing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let dotSize: CGFloat = 6
    private let spacing: CGFloat = 5

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                if reduceMotion {
                    dot.opacity(0.7)
                } else {
                    // Shared phase clock: every dot cycles 0→1→2 on the same
                    // 0.5 s beat and lights up on its own slot, so the pulse
                    // travels across the row without per-dot delay state.
                    dot
                        .phaseAnimator([0, 1, 2]) { content, phase in
                            content
                                .scaleEffect(phase == index ? 1.3 : 0.8)
                                .opacity(phase == index ? 1.0 : 0.4)
                        } animation: { _ in
                            .easeInOut(duration: 0.5)
                        }
                }
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: dotSize, height: dotSize)
    }
}

#Preview("Transcribing Indicator") {
    HStack(spacing: 12) {
        TranscribingIndicator()
        Text("Transcribiendo...")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
    }
    .padding(20)
}
