//
//  RecordingOverlayPills.swift
//  SapoWhisper
//

import Combine
import SwiftUI

struct RecordingPillView: View {
    let duration: TimeInterval
    let onPause: () -> Void
    let audioLevelPublisher: AnyPublisher<Float, Never>
    var showsNoSpeechHint: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .recording, size: 32)
            PillDivider()
            MiniEqualizerView(audioLevelPublisher: audioLevelPublisher)

            if showsNoSpeechHint {
                HStack(spacing: 5) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("overlay.no_speech".localized)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.sapoError)
                .transition(.opacity)
            } else {
                Text("overlay.recording".localized)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

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

struct PausedPillView: View {
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

struct TranscribingPillView: View {
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

struct AIPolishingPillView: View {
    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: .polishing, size: 32)
            PillDivider()
            TranscribingIndicator(color: .aiPolish)

            Text("overlay.ai_polishing".localized)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            // L10: countdown to the polish timeout — the user sees the worst
            // case shrinking instead of an open-ended spinner.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startedAt))
                let remaining = max(0, Int(TranscriptPostProcessor.polishTimeoutSeconds) - elapsed)
                Text("\(remaining)s")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .onAppear { startedAt = Date() }
    }
}

struct CompletedPillView: View {
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
        .overlay(glowStroke(color: .sapoGreen, isVisible: showGlow))
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5).delay(0.1)) {
                iconScale = 1.0
            }
            animateGlow()
        }
    }

    private func animateGlow() {
        withAnimation(.easeIn(duration: 0.3).delay(0.15)) {
            showGlow = true
        }
        withAnimation(.easeOut(duration: 0.8).delay(1.2)) {
            showGlow = false
        }
    }
}

struct ErrorPillView: View {
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
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if let onRetry {
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
        .overlay(glowStroke(color: .sapoError, isVisible: showGlow))
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

struct DeviceDetectedPillView: View {
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

struct PillDivider: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
    }
}

private func glowStroke(color: Color, isVisible: Bool) -> some View {
    Capsule()
        .strokeBorder(color.opacity(isVisible ? 0.4 : 0), lineWidth: 1.5)
        .padding(.horizontal, -20)
        .padding(.vertical, -10)
}
