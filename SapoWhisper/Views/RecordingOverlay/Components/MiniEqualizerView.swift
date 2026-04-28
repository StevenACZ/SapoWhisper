//
//  MiniEqualizerView.swift
//  SapoWhisper
//

import SwiftUI

/// Compact recorder meter with deterministic bars and bounded animation work.
struct MiniEqualizerView: View {
    let audioLevel: Float

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 20
    private let minHeight: CGFloat = 5
    private let weights: [CGFloat] = [0.58, 0.82, 1.0, 0.76, 0.62]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(weights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.recording.opacity(barOpacity(for: index)))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.07), value: displayLevel)
    }

    private var displayLevel: CGFloat {
        max(0.12, min(1.0, CGFloat(audioLevel)))
    }

    private func barHeight(for index: Int) -> CGFloat {
        let activeHeight = (maxHeight - minHeight) * displayLevel * weights[index]
        return min(maxHeight, minHeight + activeHeight)
    }

    private func barOpacity(for index: Int) -> Double {
        let normalized = barHeight(for: index) / maxHeight
        return 0.45 + Double(normalized) * 0.55
    }
}
