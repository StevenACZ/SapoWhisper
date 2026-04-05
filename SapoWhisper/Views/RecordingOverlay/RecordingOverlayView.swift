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
            .onAppear {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
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
            ErrorPillView(message: message, onRetry: manager.onRetry)

        case .streaming(_, let duration):
            RecordingPillView(
                duration: duration,
                onPause: { manager.onPauseToggle?() }
            )

        case .deviceDetected(let deviceName):
            DeviceDetectedPillView(deviceName: deviceName)
        }
    }
}

// MARK: - Recording Pill View

private struct RecordingPillView: View {
    let duration: TimeInterval
    let onPause: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .recording, size: 32)

            PillDivider()

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.recording)
                    .frame(width: 7, height: 7)
                    .modifier(PulseAnimation())

                Text("overlay.recording".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 20)

            Button(action: onPause) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)

            OverlayTimer(duration: duration)
        }
        .frame(minWidth: 300)
    }
}

// MARK: - Paused Pill View

private struct PausedPillView: View {
    let duration: TimeInterval
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .paused, size: 32)

            PillDivider()

            HStack(spacing: 6) {
                Circle()
                    .fill(Color.processing)
                    .frame(width: 7, height: 7)

                Text("overlay.paused".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 20)

            Button(action: onResume) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)

            OverlayTimer(duration: duration)
        }
        .frame(minWidth: 300)
    }
}

// MARK: - Transcribing Pill View

private struct TranscribingPillView: View {
    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .transcribing, size: 32)

            PillDivider()

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
            ZStack(alignment: .topTrailing) {
                FloatingSapoIcon(state: .completed, size: 32)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.sapoGreen)
                    .background(Circle().fill(.white).padding(1))
                    .scaleEffect(checkmarkScale)
                    .offset(x: 3, y: -3)
            }
            .frame(width: 36, height: 36)

            Text("overlay.completed".localized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sapoGreen)

            if !text.isEmpty {
                Text(text.prefix(40) + (text.count > 40 ? "..." : ""))
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
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(.sapoError)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let onRetry = onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Retry")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Device Detected Pill View

private struct DeviceDetectedPillView: View {
    let deviceName: String

    @State private var checkScale: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 18))
                .foregroundColor(.sapoGreen)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("overlay.device_ready".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.sapoGreen)
                .scaleEffect(checkScale)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.2)) {
                checkScale = 1.0
            }
        }
    }
}

// MARK: - Shared Components

private struct PillDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
    }
}

private struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

// MARK: - Preview Helper

private struct PillPreview<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                )
                .fixedSize()
        }
        .frame(width: 460, height: 100)
    }
}

// MARK: - Previews

#Preview("Recording") {
    PillPreview { RecordingPillView(duration: 15, onPause: {}) }
}

#Preview("Paused") {
    PillPreview { PausedPillView(duration: 42, onResume: {}) }
}

#Preview("Transcribing") {
    PillPreview { TranscribingPillView() }
}

#Preview("Completed") {
    PillPreview { CompletedPillView(text: "Hola, esta es una transcripcion") }
}

#Preview("Error") {
    PillPreview { ErrorPillView(message: "No se pudo conectar", onRetry: {}) }
}

#Preview("Device Detected") {
    PillPreview { DeviceDetectedPillView(deviceName: "MacBook Pro Microphone") }
}
