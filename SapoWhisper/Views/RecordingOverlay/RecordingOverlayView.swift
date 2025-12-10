//
//  RecordingOverlayView.swift
//  SapoWhisper
//
//  Created by Claude on 9/12/24.
//

import SwiftUI

/// Vista principal del overlay de grabacion
/// Muestra diferentes contenidos segun el estado actual
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    // Animaciones
    @State private var scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            // Fondo con bordes redondeados
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)

            // Contenido segun estado
            contentForState
                .padding(24)
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 32))
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
            RecordingStateView(duration: duration, audioLevel: manager.audioLevel)

        case .transcribing:
            TranscribingStateView()

        case .completed(let text):
            CompletedStateView(text: text)

        case .error(let message):
            ErrorStateView(message: message)
        }
    }

}

// MARK: - Recording State View

private struct RecordingStateView: View {
    let duration: TimeInterval
    let audioLevel: Float

    var body: some View {
        VStack(spacing: 14) {
            // Icono del sapo flotando (mas grande y centrado)
            FloatingSapoIcon(state: .recording, size: 80)
                .padding(.top, 8)

            // Ecualizador
            AudioEqualizerView(audioLevel: audioLevel)
                .frame(height: 50)

            // Estado y tiempo
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.recording)
                    .frame(width: 8, height: 8)
                    .modifier(PulseAnimation())

                Text("overlay.recording".localized)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }

            OverlayTimer(duration: duration)
        }
    }
}

// MARK: - Transcribing State View

private struct TranscribingStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Icono del sapo con pulso (mas grande)
            FloatingSapoIcon(state: .transcribing, size: 80)

            // Indicador de carga
            TranscribingIndicator()

            // Texto
            Text("overlay.transcribing".localized)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Completed State View

private struct CompletedStateView: View {
    let text: String

    @State private var checkmarkScale: CGFloat = 0
    @State private var checkmarkRotation: Double = -30

    var body: some View {
        VStack(spacing: 16) {
            // Icono del sapo con checkmark (mas grande)
            ZStack {
                FloatingSapoIcon(state: .completed, size: 80)

                // Checkmark badge
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.sapoGreen)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: 28, y: -28)
                    .scaleEffect(checkmarkScale)
                    .rotationEffect(.degrees(checkmarkRotation))
            }

            // Preview del texto
            if !text.isEmpty {
                Text(text.prefix(100) + (text.count > 100 ? "..." : ""))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            // Texto de exito
            Text("overlay.completed".localized)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.sapoGreen)
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.2)) {
                checkmarkScale = 1.0
                checkmarkRotation = 0
            }
        }
    }
}

// MARK: - Error State View

private struct ErrorStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            // Icono de error
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.sapoError)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
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

