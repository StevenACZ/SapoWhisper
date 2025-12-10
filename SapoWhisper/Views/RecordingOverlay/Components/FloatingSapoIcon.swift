//
//  FloatingSapoIcon.swift
//  SapoWhisper
//

import SwiftUI

/// Estado del icono del sapo para determinar animacion e imagen
enum SapoIconState {
    case recording
    case transcribing
    case completed
    case error

    var imageName: String {
        switch self {
        case .recording:
            return "DockIconRecording"
        case .transcribing:
            return "DockIconTranscribing"
        case .completed, .error:
            return "DockIconIdle"
        }
    }
}

/// Icono del sapo con animacion de flotacion
struct FloatingSapoIcon: View {

    let state: SapoIconState
    let size: CGFloat

    @State private var floatOffset: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0

    init(state: SapoIconState, size: CGFloat = 60) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Image(state.imageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
            .offset(y: floatOffset)
            .onAppear { startAnimations() }
            .onChange(of: state) { _, _ in startAnimations() }
    }

    private func startAnimations() {
        floatOffset = 0
        pulseScale = 1.0

        switch state {
        case .recording:
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                floatOffset = -8
            }
        case .transcribing:
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }
        case .completed:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                pulseScale = 1.15
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.2)) {
                pulseScale = 1.0
            }
        case .error:
            withAnimation(.easeInOut(duration: 0.1).repeatCount(3)) {
                floatOffset = -3
            }
        }
    }
}
