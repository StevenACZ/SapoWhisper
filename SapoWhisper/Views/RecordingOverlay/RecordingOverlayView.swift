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
        ZStack {
            contentForState
                .id(stateCategory)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94)).animation(.easeOut(duration: 0.2)),
                    removal: .opacity.combined(with: .scale(scale: 0.94)).animation(.easeIn(duration: 0.15))
                ))
        }
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
                audioLevel: manager.audioLevel
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
                onPause: { manager.onPauseToggle?() },
                audioLevel: manager.audioLevel
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
    var audioLevel: Float = 0

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .recording, size: 32)

            PillDivider()

            MiniEqualizerView(audioLevel: audioLevel)

            Text("overlay.recording".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            Spacer(minLength: 12)

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
        .frame(minWidth: 250)
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
        .frame(minWidth: 250)
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

    @State private var iconScale: CGFloat = 0
    @State private var showGlow = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 16))
                .foregroundColor(.sapoGreen)
                .scaleEffect(iconScale)

            Text("overlay.copied".localized)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.sapoGreen)

            if !text.isEmpty && text.count <= 30 {
                PillDivider()

                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .overlay(
            Capsule()
                .strokeBorder(Color.sapoGreen.opacity(showGlow ? 0.4 : 0), lineWidth: 1.5)
                .padding(.horizontal, -20)
                .padding(.vertical, -10)
        )
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
            withAnimation(.easeIn(duration: 0.3).delay(0.15)) {
                showGlow = true
            }
            withAnimation(.easeOut(duration: 0.8).delay(1.2)) {
                showGlow = false
            }
        }
    }
}

// MARK: - Error Pill View

private struct ErrorPillView: View {
    let message: String
    var onRetry: (() -> Void)?

    @State private var showGlow = false

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
                        Text("overlay.retry".localized)
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
        .overlay(
            Capsule()
                .strokeBorder(Color.sapoError.opacity(showGlow ? 0.4 : 0), lineWidth: 1.5)
                .padding(.horizontal, -20)
                .padding(.vertical, -10)
        )
        .onAppear {
            withAnimation(.easeIn(duration: 0.3).delay(0.15)) {
                showGlow = true
            }
            withAnimation(.easeOut(duration: 0.8).delay(1.2)) {
                showGlow = false
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

// MARK: - Mini Equalizer (Recording Pill)

/// Ecualizador compacto optimizado para el pill de grabación
/// Barras gruesas con color recording que reaccionan al nivel de audio
private struct MiniEqualizerView: View {
    let audioLevel: Float

    private let barCount = 5
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 20
    private let minHeight: CGFloat = 5

    @State private var barHeights: [CGFloat] = []

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.recording.opacity(barOpacity(for: index)))
                    .frame(width: barWidth, height: barHeights.isEmpty ? minHeight : barHeights[index])
            }
        }
        .frame(height: maxHeight)
        .onAppear { initBars() }
        .onChange(of: audioLevel) { _, newValue in updateBars(with: newValue) }
    }

    private func initBars() {
        barHeights = (0..<barCount).map { i in
            let position = Double(i) / Double(barCount - 1)
            let weight = 0.5 + 0.5 * (1.0 - abs(position - 0.5) * 2.0)
            let level = max(0.15, CGFloat(audioLevel))
            return max(minHeight, level * maxHeight * CGFloat(weight) * CGFloat.random(in: 0.8...1.2))
        }
    }

    private func updateBars(with level: Float) {
        let clamped = max(0.15, level)
        var newHeights: [CGFloat] = []

        for i in 0..<barCount {
            let position = Double(i) / Double(barCount - 1)
            let weight = 0.5 + 0.5 * (1.0 - abs(position - 0.5) * 2.0)
            let target = max(minHeight, CGFloat(clamped) * maxHeight * CGFloat(weight) * CGFloat.random(in: 0.8...1.2))
            let current = barHeights.isEmpty ? minHeight : barHeights[i]
            newHeights.append(min(maxHeight, current * 0.3 + target * 0.7))
        }

        withAnimation(.easeOut(duration: 0.08)) {
            barHeights = newHeights
        }
    }

    private func barOpacity(for index: Int) -> Double {
        guard !barHeights.isEmpty else { return 0.5 }
        let normalized = barHeights[index] / maxHeight
        return 0.5 + Double(normalized) * 0.5
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
    PillPreview { RecordingPillView(duration: 15, onPause: {}, audioLevel: 0.5) }
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

#Preview("Animated Transitions") {
    struct TransitionDemo: View {
        @State private var stateIndex = 0

        private var states: [(String, AnyView)] {
            [
                ("Recording", AnyView(RecordingPillView(duration: 15, onPause: {}, audioLevel: 0.5))),
                ("Paused", AnyView(PausedPillView(duration: 15, onResume: {}))),
                ("Transcribing", AnyView(TranscribingPillView())),
                ("Completed", AnyView(CompletedPillView(text: "Hola mundo transcrito"))),
                ("Error", AnyView(ErrorPillView(message: "Sin conexión", onRetry: {})))
            ]
        }

        var body: some View {
            VStack(spacing: 24) {
                ZStack {
                    Color.black.opacity(0.3)

                    ZStack {
                        states[stateIndex].1
                            .id(stateIndex)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.94)),
                                removal: .opacity.combined(with: .scale(scale: 0.94))
                            ))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    )
                    .fixedSize()
                    .frame(maxWidth: 380, maxHeight: 48)
                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: stateIndex)
                }
                .frame(width: 460, height: 120)

                HStack(spacing: 8) {
                    ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                        Button(state.0) {
                            withAnimation { stateIndex = index }
                        }
                        .buttonStyle(.bordered)
                        .tint(index == stateIndex ? .blue : .gray)
                    }
                }
            }
            .frame(width: 500)
        }
    }
    return TransitionDemo()
}
