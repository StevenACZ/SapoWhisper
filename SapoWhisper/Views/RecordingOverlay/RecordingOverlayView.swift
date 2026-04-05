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
        ZStack {
            if isStreamingState {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            } else {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            }

            contentForState
                .padding(.horizontal, isStreamingState ? 16 : 28)
                .padding(.vertical, isStreamingState ? 10 : 8)
        }
        .frame(width: isStreamingState ? 520 : 480, height: isStreamingState ? 100 : 56)
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                scale = 1.0
            }
        }
    }

    private var isStreamingState: Bool {
        if case .streaming = manager.state { return true }
        return false
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
            ErrorPillView(message: message, onRetry: manager.onRetry)

        case .streaming(let partialText, let duration):
            StreamingPillView(
                partialText: partialText,
                duration: duration,
                audioLevel: manager.audioLevel,
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
    let audioLevel: Float
    let onPause: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FloatingSapoIcon(state: .recording, size: 44)
                .padding(.trailing, 8)

            AudioEqualizerView(audioLevel: audioLevel)
                .frame(width: 100)

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
            FloatingSapoIcon(state: .paused, size: 44)

            // Flat bars to indicate paused
            HStack(spacing: 2) {
                ForEach(0..<20, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 3, height: 3)
                }
            }
            .frame(width: 100, height: 28)

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
            FloatingSapoIcon(state: .transcribing, size: 44)

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
                FloatingSapoIcon(state: .completed, size: 44)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sapoGreen)
                    .background(Circle().fill(.white).padding(1))
                    .offset(x: 16, y: -16)
                    .scaleEffect(checkmarkScale)
            }

            Text("overlay.completed".localized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sapoGreen)

            if !text.isEmpty {
                Text(text.prefix(50) + (text.count > 50 ? "..." : ""))
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
                .font(.system(size: 20))
                .foregroundColor(.sapoError)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

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
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
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
        HStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 22))
                .foregroundColor(.sapoGreen)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("overlay.device_ready".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
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

// MARK: - Streaming Pill View

private struct StreamingPillView: View {
    let partialText: String
    let duration: TimeInterval
    let audioLevel: Float
    let onPause: () -> Void

    // Fix #5: Show last 2 lines with manual text slicing
    private var displayText: String {
        if partialText.isEmpty { return "" }
        let charsPerLine = 55
        let text = partialText
        if text.count <= charsPerLine * 2 {
            return text
        }
        let startIndex = text.index(text.endIndex, offsetBy: -(charsPerLine * 2), limitedBy: text.startIndex) ?? text.startIndex
        return "..." + String(text[startIndex...])
    }

    private var timerText: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Text area — full width with placeholder
            Text(displayText.isEmpty ? "overlay.streaming".localized : displayText)
                .font(.system(size: 13, weight: displayText.isEmpty ? .medium : .regular))
                .foregroundColor(displayText.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .animation(.none, value: partialText)

            // Controls row
            HStack(spacing: 0) {
                FloatingSapoIcon(state: .recording, size: 30)

                Spacer().frame(width: 12)

                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 18)

                Spacer().frame(width: 12)

                Circle()
                    .fill(Color.recording)
                    .frame(width: 6, height: 6)
                    .modifier(PulseAnimation())

                Spacer().frame(width: 10)

                AudioEqualizerView(audioLevel: audioLevel, barCount: 8, barWidth: 4)
                    .frame(width: 46, height: 22)

                Spacer()

                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Spacer().frame(width: 10)

                Text(timerText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
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

// MARK: - Previews

#Preview("Recording") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            RecordingPillView(duration: 15, audioLevel: 0.5, onPause: {})
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Paused") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            PausedPillView(duration: 42, onResume: {})
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Transcribing") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            TranscribingPillView()
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Completed") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            CompletedPillView(text: "Hola, esta es una transcripcion de ejemplo completa")
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Error") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            ErrorPillView(message: "No se pudo conectar al servidor", onRetry: {})
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Device Detected") {
    ZStack {
        Color.black.opacity(0.3)
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            DeviceDetectedPillView(deviceName: "MacBook Pro Microphone")
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: 480, height: 56)
    }
    .frame(width: 560, height: 120)
}

#Preview("Streaming Overlay") {
    ZStack {
        Color.black.opacity(0.3)

        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)

            StreamingPillView(
                partialText: "...por lo que veo realmente es lo está haciendo. Es algo que me gusta y realmente creo que será un buen avance para sapo whisper.",
                duration: 22,
                audioLevel: 0.4,
                onPause: {}
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 100)
    }
    .frame(width: 600, height: 200)
}

#Preview("Streaming Empty") {
    ZStack {
        Color.black.opacity(0.3)

        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)

            StreamingPillView(
                partialText: "",
                duration: 2,
                audioLevel: 0.6,
                onPause: {}
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 100)
    }
    .frame(width: 600, height: 200)
}
