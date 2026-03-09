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

    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)

            contentForState
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
        .clipShape(Capsule())
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
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
                audioLevel: manager.audioLevel,
                onPause: { manager.onPauseToggle?() }
            )

        case .paused(let duration):
            PausedPillView(
                duration: duration,
                onResume: { manager.onPauseToggle?() }
            )

        case .transcribing:
            TranscribingPillView()

        case .completed(let text):
            CompletedPillView(text: text)

        case .error(let message):
            ErrorPillView(message: message)
        }
    }
}

// MARK: - Recording Pill View

private struct RecordingPillView: View {
    let duration: TimeInterval
    let audioLevel: Float
    let onPause: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FloatingSapoIcon(state: .recording, size: 36)

            AudioEqualizerView(audioLevel: audioLevel)
                .frame(width: 120)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.recording)
                    .frame(width: 6, height: 6)
                    .modifier(PulseAnimation())

                Text("overlay.recording".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Button(action: onPause) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)

            OverlayTimer(duration: duration)
        }
    }
}

// MARK: - Paused Pill View

private struct PausedPillView: View {
    let duration: TimeInterval
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FloatingSapoIcon(state: .paused, size: 36)

            // Flat bars to indicate paused
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: 120, height: 28)

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.processing)
                    .frame(width: 6, height: 6)

                Text("overlay.paused".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Button(action: onResume) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)

            OverlayTimer(duration: duration)
        }
    }
}

// MARK: - Transcribing Pill View

private struct TranscribingPillView: View {
    var body: some View {
        HStack(spacing: 12) {
            FloatingSapoIcon(state: .transcribing, size: 36)

            TranscribingIndicator()

            Text("overlay.transcribing".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Completed Pill View

private struct CompletedPillView: View {
    let text: String

    @State private var checkmarkScale: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                FloatingSapoIcon(state: .completed, size: 36)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sapoGreen)
                    .background(Circle().fill(.white).padding(1))
                    .offset(x: 14, y: -14)
                    .scaleEffect(checkmarkScale)
            }

            Text("overlay.completed".localized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sapoGreen)

            if !text.isEmpty {
                Text(text.prefix(60) + (text.count > 60 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.2)) {
                checkmarkScale = 1.0
            }
        }
    }
}

// MARK: - Error Pill View

private struct ErrorPillView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(.sapoError)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}
