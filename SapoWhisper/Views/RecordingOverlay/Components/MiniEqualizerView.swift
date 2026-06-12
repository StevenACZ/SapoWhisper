//
//  MiniEqualizerView.swift
//  SapoWhisper
//

import Combine
import SwiftUI

/// Compact recorder meter with deterministic bars and bounded animation work.
///
/// The incoming level is the source's -60..0 dB normalization, which crushes
/// speech into the middle of the scale. The view re-expands the speech band
/// (gating room noise to a flat baseline), applies a fast-attack/slow-release
/// envelope, and ripples it outward from the center bar so the bars visibly
/// follow the voice instead of scaling one shared value.
struct MiniEqualizerView: View {
    let audioLevelPublisher: AnyPublisher<Float, Never>

    @State private var envelope: CGFloat = 0
    @State private var barLevels: [CGFloat] = [0, 0, 0, 0, 0]

    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 20
    private let minHeight: CGFloat = 4
    private let weights: [CGFloat] = [0.6, 0.84, 1.0, 0.78, 0.64]

    // Speech window over the source's -60..0 dB scale: below ~-44 dB reads as
    // silence (flat bars), ~-14 dB and louder pins the meter at full height.
    private let silenceFloor: CGFloat = 0.27
    private let speechCeiling: CGFloat = 0.77

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.recording.opacity(barOpacity(for: index)))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(height: maxHeight)
        .onReceive(audioLevelPublisher.receive(on: RunLoop.main)) { audioLevel in
            ingest(CGFloat(audioLevel))
        }
    }

    private func ingest(_ rawLevel: CGFloat) {
        let banded = min(1, max(0, (rawLevel - silenceFloor) / (speechCeiling - silenceFloor)))
        let shaped = banded > 0 ? CGFloat(pow(Double(banded), 0.85)) : 0

        let attack: CGFloat = 0.6
        let release: CGFloat = 0.25
        let blend = shaped > envelope ? attack : release
        var nextEnvelope = envelope + (shaped - envelope) * blend
        if nextEnvelope < 0.015 { nextEnvelope = 0 }

        // Skip state writes (and re-renders) while everything is already flat.
        if nextEnvelope == 0, envelope == 0, barLevels.allSatisfy({ $0 == 0 }) { return }

        envelope = nextEnvelope

        // Center bar carries the live envelope; neighbors echo previous ticks
        // so speech ripples outward and silence collapses back to a flat line.
        var levels = barLevels
        levels[0] = barLevels[1]
        levels[4] = barLevels[3]
        levels[1] = barLevels[2]
        levels[3] = barLevels[2]
        levels[2] = nextEnvelope

        withAnimation(.easeOut(duration: 0.09)) {
            barLevels = levels
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let activeHeight = (maxHeight - minHeight) * barLevels[index] * weights[index]
        return min(maxHeight, minHeight + activeHeight)
    }

    private func barOpacity(for index: Int) -> Double {
        return 0.5 + Double(barLevels[index]) * 0.5
    }
}
