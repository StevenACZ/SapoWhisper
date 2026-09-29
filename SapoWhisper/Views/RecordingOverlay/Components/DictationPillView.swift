//
//  DictationPillView.swift
//  SapoWhisper
//

import Combine
import SwiftUI

/// One pill for the whole dictation: recording, paused, transcribing and
/// polishing keep a single view identity, so the frog, the controls and the
/// timer stay where they are and only the pieces that change cross-fade in
/// place. Separate pills per phase made every hand-off blink, resize and pop.
struct DictationPillView: View {
    enum Phase: Equatable {
        case recording
        case paused
        case transcribing
        case polishing(timeoutSeconds: UInt64, compact: Bool)
    }

    let phase: Phase
    /// Take length: live while capturing, frozen while it is processed.
    let duration: TimeInterval?
    let audioLevelPublisher: AnyPublisher<Float, Never>
    var showsNoSpeechHint = false
    /// Non-nil while the input still delivers dead air (Bluetooth handshake).
    var connectingDeviceName: String?
    var cancelWarningActive = false
    var resumeOffer: OverlayWindowManager.ResumeOffer?
    /// Compact polish will really run for this take: purple meter + chip.
    var compactModeActive = false
    /// The processing can be cancelled without losing the audio. The button
    /// holds its slot while this is false so the pill never jumps in width.
    var canCancel = false
    var onPauseToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResumeToggle: (() -> Void)?
    var onTranslationToggled: ((Bool) -> Void)?

    @AppStorage(Constants.StorageKeys.aiPolishEnabled, store: AppPreferences.defaults) private var aiPolishEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Flips once the pill is on screen; each piece settles in a beat after
    /// the one before it.
    @State private var entered = false

    private var isCapturing: Bool {
        phase == .recording || phase == .paused
    }

    var body: some View {
        HStack(spacing: 10) {
            FloatingSapoIcon(state: iconState, size: 32)
                .modifier(entered ? OverlayPresence() : OverlayPresence(scale: 0.3, opacity: 0))
                .animation(settle(after: 0), value: entered)
            PillDivider()
            activity
                .modifier(entered ? OverlayPresence() : OverlayPresence(scale: 0.2, anchor: .leading, opacity: 0))
                .animation(settle(after: 0.04), value: entered)
            status
                .modifier(entered ? OverlayPresence() : OverlayPresence(x: -10, blur: 4, opacity: 0))
                .animation(settle(after: 0.07), value: entered)
            trailing
                .padding(.leading, 4)
                .modifier(entered ? OverlayPresence() : OverlayPresence(scale: 0.6, opacity: 0))
                .animation(settle(after: 0.1), value: entered)
        }
        .animation(.smooth(duration: 0.25), value: compactModeActive)
        .onAppear { entered = true }
    }

    private func settle(after delay: TimeInterval) -> Animation? {
        reduceMotion ? nil : Constants.Animation.settle.delay(delay)
    }

    private var iconState: SapoIconState {
        switch phase {
        case .recording: .recording
        case .paused: .paused
        case .transcribing: .transcribing
        case .polishing: .polishing
        }
    }

    private var meterColor: Color {
        let base: Color = compactModeActive ? .compactMode : .recording
        return phase == .paused ? base.opacity(0.35) : base
    }

    private var processingColor: Color {
        switch phase {
        case .polishing(_, let compact): compact ? .compactMode : .aiPolish
        default: .processing
        }
    }

    private var activity: some View {
        ZStack {
            if isCapturing {
                MiniEqualizerView(
                    audioLevelPublisher: audioLevelPublisher,
                    barCount: 11,
                    isConnecting: connectingDeviceName != nil,
                    barColor: meterColor
                )
                .transition(.presence(OverlayPresence(scale: 0.3, blur: 3, opacity: 0)))
            } else {
                TranscribingIndicator(color: processingColor)
                    .transition(.presence(OverlayPresence(scale: 0.3, blur: 3, opacity: 0)))
            }
        }
    }

    private var statusTitle: String {
        switch phase {
        case .recording: "overlay.recording".localized
        case .paused: "overlay.paused".localized
        case .transcribing: "overlay.transcribing".localized
        case .polishing(_, let compact): (compact ? "overlay.ai_compacting" : "overlay.ai_polishing").localized
        }
    }

    private var status: some View {
        ZStack(alignment: .leading) {
            if cancelWarningActive {
                CancelWarningHint()
                    .transition(.statusSwap)
            } else if isCapturing, let connectingDeviceName {
                Text("overlay.mic_connecting".localized(connectingDeviceName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.statusSwap)
            } else if phase == .recording, showsNoSpeechHint {
                HStack(spacing: 5) {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("overlay.no_speech".localized)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.sapoError)
                .fixedSize()
                .transition(.statusSwap)
            } else {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .id(statusTitle)
                    .transition(.statusSwap)
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            if isCapturing {
                if let resumeOffer {
                    ResumePreviousChip(offer: resumeOffer, onTap: { onResumeToggle?() })
                }
                if compactModeActive {
                    CompactModeChip()
                        .transition(.controlSwap)
                }
                if aiPolishEnabled {
                    OverlayTranslationChip(onTranslationToggled: onTranslationToggled)
                }

                OverlayIconButton(
                    systemName: phase == .paused ? "play.fill" : "pause.fill",
                    label: (phase == .paused ? "overlay.a11y.resume" : "overlay.a11y.pause").localized,
                    diameter: 26,
                    iconSize: 11,
                    action: { onPauseToggle?() }
                )
                .transition(.controlSwap)
            } else {
                OverlayIconButton(
                    systemName: "xmark",
                    label: "overlay.cancel_processing".localized,
                    help: "overlay.cancel_processing".localized,
                    diameter: 26,
                    iconSize: 11,
                    action: { onCancel?() }
                )
                .disabled(!canCancel)
                .opacity(canCancel ? 1 : 0.35)
                .animation(.easeOut(duration: 0.15), value: canCancel)
                .transition(.controlSwap)
            }

            timer
                .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var timer: some View {
        if case .polishing(let timeoutSeconds, _) = phase {
            PolishCountdown(timeoutSeconds: timeoutSeconds)
                .transition(.opacity)
        } else if let duration {
            OverlayTimer(duration: duration)
                .opacity(isCapturing ? 1 : 0.5)
        }
    }
}

/// Countdown to the polish timeout: the worst case shrinks instead of an
/// open-ended spinner.
private struct PolishCountdown: View {
    let timeoutSeconds: UInt64

    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt))
            let remaining = max(0, Int(timeoutSeconds) - elapsed)
            Text("\(remaining)s")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
                .animation(Constants.Animation.tick, value: remaining)
        }
        .onAppear { startedAt = Date() }
    }
}
