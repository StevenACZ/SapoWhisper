//
//  RecordingOverlayView.swift
//  SapoWhisper
import SwiftUI

/// Window-relative frame of the pill inside the fixed transparent surface
/// (`.global` in a hosting view is window space).
struct OverlayContentFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Vista principal del overlay de grabacion. Every active state (recording,
/// transcribing, completed, ...) is one pill that pops out of the configured
/// screen edge and sinks back into it; idle draws nothing. The pill enters as
/// one finished unit (background + content together), so there is never an
/// empty background morph or content sticking out of a half-grown pill.
struct RecordingOverlayView: View {

    @ObservedObject var manager: OverlayWindowManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stateCategory: String { manager.state.stateCategory }
    private var contentFamily: String { manager.state.contentFamily }
    private var isActive: Bool { stateCategory != "hidden" && stateCategory != "docked" }
    private var anchorsTop: Bool { OverlayPosition.configured == .top }
    private var pressPhase: PressPhase {
        switch manager.state {
        case .transcribing, .polishing: .processing
        case .cancelled: .cancelled
        default: .none
        }
    }

    /// Where the content rests inside the fixed transparent surface.
    private var surfaceAlignment: Alignment {
        switch OverlayPosition.configured {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        }
    }

    var body: some View {
        pillStack
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
            .padding(anchorsTop ? .top : .bottom, 20)
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
    }

    private var pillStack: some View {
        ZStack {
            if isActive {
                activePill
                    .transition(pillTransition)
            }
        }
    }

    /// The pill pops out of the screen edge with a small overshoot and sinks
    /// back into it. Opacity lands within the first frames of the spring, so
    /// the pill reads as open at once while the scale settles.
    private var pillTransition: AnyTransition {
        let edge: UnitPoint = anchorsTop ? .top : .bottom
        let lift: CGFloat = anchorsTop ? -16 : 16
        return .presence(
            in: OverlayPresence(scale: 0.55, anchor: edge, y: lift, blur: 10, opacity: 0),
            out: OverlayPresence(scale: 0.8, anchor: edge, y: lift * 0.75, blur: 8, opacity: 0)
        )
    }

    private var contentSwapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.05)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
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
                        Label(
                            stateCategory == "copied" ? notice.completedTitle : notice.title,
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: stateCategory == "copied" ? 11 : 12, weight: .medium))
                        .foregroundStyle(stateCategory == "copied" ? Color.secondary : Color.sapoGreenText)
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
            .id(contentFamily)
            .transition(contentSwapTransition)
        }
        .padding(.horizontal, OverlayPillChrome.horizontalPadding)
        .padding(.vertical, OverlayPillChrome.verticalPadding)
        .background {
            // The fill belongs to the dictation it cancels: it dissolves with
            // the outgoing content instead of draining inside the next pill.
            CancelHoldFill(progress: manager.cancelHoldProgress)
                .opacity(contentFamily == "dictation" ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: contentFamily)
        }
        .clipShape(OverlayPillChrome.pillShape)
        .overlayPillChrome()
        .overlay {
            switch manager.state {
            case .copied(let outcome):
                PillGlowFlash(color: outcome == .aiSkipped ? .sapoError : .sapoGreen)
            case .cancelled:
                PillGlowFlash(color: .red)
            default:
                EmptyView()
            }
        }
        // Armed-cancel heartbeat: a double "lub-dub" each time Esc arms the
        // cancel, so the warning is felt even without reading the hint.
        .keyframeAnimator(initialValue: 1.0, trigger: manager.cancelWarningPulse) {
            [reduceMotion] content, beatScale in
            content.scaleEffect(reduceMotion ? 1.0 : beatScale)
        } keyframes: { _ in
            HeartbeatKeyframes()
        }
        // Stopping the take or confirming a cancel presses the pill in and
        // lets it spring back, so the hand-off is felt as well as read.
        .keyframeAnimator(initialValue: 1.0, trigger: pressPhase) {
            [reduceMotion] content, pressScale in
            content.scaleEffect(reduceMotion ? 1.0 : pressScale)
        } keyframes: { _ in
            PressKeyframes()
        }
    }

    // MARK: - Content Views

    /// Every dictation phase renders through ONE branch: a switch case per
    /// phase would give each its own identity and rebuild the pill on every
    /// hand-off.
    @ViewBuilder
    private var contentForState: some View {
        if let dictation = dictationPhase {
            dictationPill(dictation.phase, duration: dictation.duration)
        } else {
            otherContent
        }
    }

    private var dictationPhase: (phase: DictationPillView.Phase, duration: TimeInterval?)? {
        switch manager.state {
        case .recording(let duration): (.recording, duration)
        case .paused(let duration): (.paused, duration)
        case .transcribing: (.transcribing, manager.processedTakeDuration)
        case .polishing(let timeoutSeconds, let compact):
            (.polishing(timeoutSeconds: timeoutSeconds, compact: compact), nil)
        default: nil
        }
    }

    @ViewBuilder
    private var otherContent: some View {
        switch manager.state {
        case .hidden, .docked, .recording, .paused, .transcribing, .polishing:
            EmptyView()

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

extension RecordingOverlayView {
    fileprivate func dictationPill(_ phase: DictationPillView.Phase, duration: TimeInterval?) -> some View {
        let capturing = phase == .recording || phase == .paused
        return DictationPillView(
            phase: phase,
            duration: duration,
            audioLevelPublisher: manager.audioLevelPublisher,
            showsNoSpeechHint: manager.showsNoSpeechHint,
            connectingDeviceName: manager.micConnectingName,
            cancelWarningActive: manager.isCancelWarningArmed,
            resumeOffer: manager.resumeOffer,
            // Purple meter + chip only once this dictation will REALLY
            // compact: below the minimum-duration threshold the polish is
            // skipped, so the accent appears live when the threshold passes.
            compactModeActive: capturing && PolishMode.compactIsActive()
                && PolishMinimumDuration.allowsPolish(duration: duration ?? 0),
            canCancel: !capturing && manager.canCancelProcessing?() == true,
            onPauseToggle: { manager.onPauseToggle?() },
            onCancel: manager.onCancelProcessing,
            onResumeToggle: { manager.toggleResumeOffer() },
            onTranslationToggled: { manager.onQuickTranslationToggled?($0) }
        )
    }
}

private enum PressPhase {
    case none, processing, cancelled
}

/// Press-in and spring-back scale when the pill changes hands.
private struct PressKeyframes: Keyframes {
    var body: some Keyframes<Double> {
        KeyframeTrack {
            CubicKeyframe(0.94, duration: 0.09)
            SpringKeyframe(1.0, duration: 0.4, spring: .init(duration: 0.4, bounce: 0.45))
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
