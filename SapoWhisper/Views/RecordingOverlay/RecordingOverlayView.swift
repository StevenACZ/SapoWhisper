//
//  RecordingOverlayView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Vista principal del overlay de grabacion - pill horizontal en la parte inferior
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    @State private var scale: CGFloat = 0.9

    private var stateCategory: String { manager.state.stateCategory }

    var body: some View {
        contentForState
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            )
            .fixedSize()
            .frame(maxWidth: 380, maxHeight: 48)
            .scaleEffect(scale)
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: stateCategory)
            .onChange(of: stateCategory) { _, _ in
                microBounce()
            }
            .onAppear {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    scale = 1.0
                }
            }
    }

    /// Micro-bounce effect when state changes — subtle scale pop for tactile feedback
    private func microBounce() {
        withAnimation(.spring(response: 0.12, dampingFraction: 0.4)) {
            scale = 1.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                scale = 1.0
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentForState: some View {
        switch manager.state {
        case .hidden:
            EmptyView()

        case .recording(let duration):
            RecordingPillView(
                duration: duration,
                onPause: { manager.onPauseToggle?() },
                audioLevelPublisher: manager.audioLevelPublisher
            )

        case .paused(let duration):
            PausedPillView(
                duration: duration,
                onResume: { manager.onPauseToggle?() }
            )

        case .transcribing:
            TranscribingPillView()

        case .polishing:
            AIPolishingPillView()

        case .completed(let text):
            CompletedPillView(text: text)

        case .error(let message, let isRetryable):
            ErrorPillView(message: message, onRetry: isRetryable ? manager.onRetry : nil)

        case .deviceDetected(let deviceName):
            DeviceDetectedPillView(deviceName: deviceName)
        }
    }
}
