//
//  RecordingOverlayView.swift
//  SapoWhisper
import SwiftUI

/// Window-relative frame of the pill + chip stack inside the fixed
/// transparent surface (`.global` in a hosting view is window space).
struct OverlayContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Vista principal del overlay de grabacion. Two-piece layout: the dock chip
/// is a permanent fixture hugging the screen edge, and every active state
/// (recording, transcribing, completed, ...) is a separate "droplet" pill that
/// detaches from the chip when it appears and is absorbed back on dismiss.
/// Because the droplet enters as one finished unit (background + content
/// together), there is never an empty background morph or content sticking
/// out of a half-grown pill.
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    @State private var pillBounceTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stateCategory: String { manager.state.stateCategory }
    private var isActive: Bool { stateCategory != "hidden" && stateCategory != "docked" }
    /// The chip hugs the configured screen edge; the droplet detaches toward
    /// the screen center, so a top-anchored overlay flips the stack.
    private var chipOnTop: Bool { OverlayPosition.configured == .top }

    /// Where the content rests inside the fixed transparent surface.
    private var surfaceAlignment: Alignment {
        switch OverlayPosition.configured {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    var body: some View {
        pillAndChipStack
            .fixedSize()
            // Publish where the real content sits inside the mostly-transparent
            // surface, so the outside-click collapse can compare against the
            // visible pill instead of the whole fixed window rect.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: OverlayContentFramePreferenceKey.self,
                        value: proxy.frame(in: .global)
                    )
                }
            )
            // Slim transparent inset on the chip side so its shadow still renders
            // while the chip visually hugs the screen edge.
            .padding(chipOnTop ? .top : .bottom, 4)
            // The hosting window is a fixed transparent surface that NEVER
            // resizes: window resizes during SwiftUI transaction animations made
            // NSHostingView animate the window frame from inside the display
            // cycle (updateAnimatedWindowSize), which throws and crashes the app.
            // The content simply lays out against the configured edge; empty
            // surface pixels are alpha-transparent, so clicks there fall through
            // to whatever is behind the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: surfaceAlignment)
            .onPreferenceChange(OverlayContentFramePreferenceKey.self) { frame in
                Task { @MainActor in
                    OverlayWindowManager.shared.setActiveContentFrame(frame)
                }
            }
            .onChange(of: stateCategory) { oldValue, _ in
                // Micro-bounce only on active-to-active swaps; dock transitions
                // are carried entirely by the droplet detach/absorb.
                guard isActive, oldValue != "hidden", oldValue != "docked" else { return }
                guard !reduceMotion else { return }
                pillBounceTrigger += 1
            }
    }

    private var pillAndChipStack: some View {
        VStack(spacing: 0) {
            if chipOnTop {
                chip
            }
            if isActive {
                activePill
                    // Small fixed gap to the chip: at the start of the detach
                    // the tiny droplet reads as connected, and once grown it
                    // reads as two separated parts with the chip peeking out.
                    .padding(chipOnTop ? .top : .bottom, 8)
                    .transition(dropletTransition)
            }
            if !chipOnTop {
                chip
            }
        }
    }

    private var chip: some View {
        DockedChipView(
            isExpanded: isActive,
            onTap: { manager.dockChipTapped() }
        )
    }

    /// The droplet grows out of the chip's edge and collapses back into it,
    /// with scale anchored at the chip side. The enter stays fully opaque so
    /// the detach reads as a drop separating from the resting chip; the exit
    /// adds a fade as the pill returns to the chip.
    private var dropletTransition: AnyTransition {
        let anchor: UnitPoint = chipOnTop ? .top : .bottom
        return .asymmetric(
            insertion: .scale(scale: 0.04, anchor: anchor),
            removal: .scale(scale: 0.04, anchor: anchor).combined(with: .opacity)
        )
    }

    private var contentSwapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.16).delay(0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    private var activePill: some View {
        // The ZStack hosts the outgoing and incoming pill contents during an
        // active-to-active swap so the pill morphs once while the texts hand
        // off sequentially.
        ZStack {
            VStack(spacing: 8) {
                contentForState
                if manager.state.showsBackupNotice, let notice = manager.backupNotice {
                    VStack(spacing: 3) {
                        Label(notice.title, systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sapoGreen)
                        Text(notice.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 320)
                    .transition(.opacity)
                }
            }
            .id(stateCategory)
            .transition(contentSwapTransition)
        }
        .padding(.horizontal, OverlayPillChrome.horizontalPadding)
        .padding(.vertical, OverlayPillChrome.verticalPadding)
        .clipShape(OverlayPillChrome.pillShape)
        .overlayPillChrome()
        // Micro-bounce on state swaps — subtle scale pop for tactile
        // feedback. Phase-driven so a swap mid-bounce can never leave the
        // pill stuck scaled up (the old detached asyncAfter could).
        .phaseAnimator([1.0, 1.05], trigger: pillBounceTrigger) { content, bounceScale in
            content.scaleEffect(bounceScale)
        } animation: { bounceScale in
            bounceScale > 1 ? Constants.Animation.microBounce : .spring(duration: 0.25, bounce: 0.3)
        }
        // Armed-cancel heartbeat: a double "lub-dub" each time Esc arms the
        // cancel, so the warning is felt even without reading the hint.
        .keyframeAnimator(initialValue: 1.0, trigger: manager.cancelWarningPulse) {
            [reduceMotion] content, beatScale in
            content.scaleEffect(reduceMotion ? 1.0 : beatScale)
        } keyframes: { _ in
            HeartbeatKeyframes()
        }
        // Pre-collapse "inhale": the manager arms this for a beat before the
        // absorb, so the pill puffs up a touch and is then swallowed by the
        // chip instead of vanishing from a standstill.
        .scaleEffect(
            manager.hideAnticipation ? 1.04 : 1.0,
            anchor: chipOnTop ? .top : .bottom
        )
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentForState: some View {
        switch manager.state {
        case .hidden, .docked:
            EmptyView()

        case .recording(let duration):
            RecordingPillView(
                duration: duration,
                onPause: { manager.onPauseToggle?() },
                audioLevelPublisher: manager.audioLevelPublisher,
                showsNoSpeechHint: manager.showsNoSpeechHint,
                connectingDeviceName: manager.micConnectingName,
                cancelWarningActive: manager.isCancelWarningArmed,
                resumeOffer: manager.resumeOffer,
                onResumeToggle: { manager.toggleResumeOffer() },
                onTranslationToggled: { manager.onQuickTranslationToggled?($0) },
                // Purple meter + chip only once this dictation will REALLY
                // compact: below the user's minimum-duration threshold the
                // polish is skipped, so the accent appears live the moment
                // the threshold is crossed.
                compactModeActive: PolishMode.compactIsActive()
                    && PolishMinimumDuration.allowsPolish(duration: duration)
            )

        case .paused(let duration):
            PausedPillView(
                duration: duration,
                cancelWarningActive: manager.isCancelWarningArmed,
                onResume: { manager.onPauseToggle?() }
            )

        case .transcribing:
            TranscribingPillView(
                cancelWarningActive: manager.isCancelWarningArmed,
                onCancel: manager.canCancelProcessing?() == true ? manager.onCancelProcessing : nil
            )

        case .polishing(let timeoutSeconds, let compact):
            AIPolishingPillView(
                timeoutSeconds: timeoutSeconds, compact: compact,
                cancelWarningActive: manager.isCancelWarningArmed,
                onCancel: manager.canCancelProcessing?() == true ? manager.onCancelProcessing : nil
            )

        case .copied(let outcome):
            CopiedPillView(outcome: outcome)

        case .completed(let text):
            CompletedPillView(
                text: text,
                onRepolish: { manager.onRepolishRequested?() },
                onOpenHistory: { manager.onOpenHistoryRequested?() },
                onClose: { manager.hide() }
            )
            .onHover { hovering in
                manager.setCompletedHover(hovering)
            }

        case .quickHistory:
            QuickHistoryPillView(
                onOpenHistory: { manager.onOpenHistoryEntryRequested?($0) },
                onRetranscribe: { await manager.onQuickHistoryRetranscribe?($0) ?? nil },
                onClose: { manager.hide() }
            )

        case .cancelled:
            CancelledPillView(message: manager.cancellationMessage)

        case .error(let message, let isRetryable):
            ErrorPillView(message: message, onRetry: isRetryable ? manager.onRetry : nil)
                .onHover { manager.setErrorHover($0) }

        case .deviceChange(let announcement):
            DeviceChangePillView(announcement: announcement)
        }
    }
}

/// Double-beat "lub-dub" scale for the armed-cancel warning.
private struct HeartbeatKeyframes: Keyframes {
    var body: some Keyframes<Double> {
        KeyframeTrack {
            CubicKeyframe(1.07, duration: 0.12)
            CubicKeyframe(0.99, duration: 0.11)
            CubicKeyframe(1.05, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
        }
    }
}
