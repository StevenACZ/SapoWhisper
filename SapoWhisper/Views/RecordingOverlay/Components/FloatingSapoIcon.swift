//
//  FloatingSapoIcon.swift
//  SapoWhisper
//

import SwiftUI

/// Estado del icono del sapo para determinar animacion e imagen
enum SapoIconState {
    case recording
    case paused
    case transcribing
    case polishing
    case completed
    case error

    var imageName: String {
        switch self {
        case .recording:
            return "DockIconRecording"
        case .paused, .completed:
            return "DockIconLoading"
        case .error:
            // The error pill already carries the red state; the mascot goes
            // back to its resting face instead of a misleading "loading".
            return "DockIconIdle"
        case .transcribing, .polishing:
            return "DockIconTranscribing"
        }
    }
}

/// Icono del sapo con animacion de flotacion
struct FloatingSapoIcon: View {

    let state: SapoIconState
    let size: CGFloat

    @State private var completedPop = 0
    @State private var errorShake = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: SapoIconState, size: CGFloat = 60) {
        self.state = state
        self.size = size
    }

    /// Looping idle pulse per state: scale target, float offset, half-period.
    private var pulse: (scale: CGFloat, offset: CGFloat, period: Double)? {
        switch state {
        case .paused: return (0.92, 0, 2.0)
        case .transcribing: return (1.08, 0, 0.8)
        case .polishing: return (1.06, -2, 1.0)
        case .recording, .completed, .error: return nil
        }
    }

    var body: some View {
        pulsingIcon
            // One-shot completed pop, keyframe-driven so a state change
            // mid-pop can never strand the icon scaled up.
            .keyframeAnimator(initialValue: 1.0, trigger: completedPop) { content, popScale in
                content.scaleEffect(popScale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.15, spring: Spring(response: 0.4, dampingRatio: 0.5))
                    SpringKeyframe(1.0, spring: Spring(response: 0.3, dampingRatio: 0.6))
                }
            }
            // Real bidirectional error shake; the old one-way -3 nudge read
            // as a tic.
            .keyframeAnimator(initialValue: 0.0, trigger: errorShake) { content, shakeOffset in
                content.offset(x: shakeOffset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-3, duration: 0.08)
                    CubicKeyframe(3, duration: 0.1)
                    CubicKeyframe(-2, duration: 0.1)
                    CubicKeyframe(2, duration: 0.1)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
            .onAppear { fireOneShotEffect() }
            .onChange(of: state) { _, _ in fireOneShotEffect() }
    }

    /// The idle pulse loops via phases (no resettable state), and rests as a
    /// static icon under Reduce Motion.
    @ViewBuilder
    private var pulsingIcon: some View {
        if let pulse, !reduceMotion {
            icon
                .phaseAnimator([false, true]) { content, pulsing in
                    content
                        .scaleEffect(pulsing ? pulse.scale : 1.0)
                        .offset(y: pulsing ? pulse.offset : 0)
                } animation: { _ in
                    .easeInOut(duration: pulse.period)
                }
        } else {
            icon
        }
    }

    private var icon: some View {
        Image(state.imageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    private func fireOneShotEffect() {
        guard !reduceMotion else { return }
        switch state {
        case .completed:
            completedPop += 1
        case .error:
            errorShake += 1
        case .recording, .paused, .transcribing, .polishing:
            break
        }
    }
}

#Preview("Sapo States") {
    HStack(spacing: 24) {
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .recording, size: 44)
            Text("Recording").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .paused, size: 44)
            Text("Paused").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .transcribing, size: 44)
            Text("Transcribing").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .polishing, size: 44)
            Text("AI").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .completed, size: 44)
            Text("Completed").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .error, size: 44)
            Text("Error").font(.caption2).foregroundStyle(.secondary)
        }
    }
    .padding(24)
}

#Preview("Sapo Sizes") {
    HStack(spacing: 20) {
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .recording, size: 24)
            Text("24px").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .recording, size: 30)
            Text("30px").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .recording, size: 44)
            Text("44px").font(.caption2).foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            FloatingSapoIcon(state: .recording, size: 60)
            Text("60px").font(.caption2).foregroundStyle(.secondary)
        }
    }
    .padding(24)
}
