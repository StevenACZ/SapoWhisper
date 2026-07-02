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
    /// Clipboard-edit sessions show a distinct label and no mode chips: the
    /// spoken instruction, not the selected mode, drives the rewrite.
    var isEditSession: Bool = false
    var onModeSelected: ((String) -> Void)?
    var onTranslationToggled: ((Bool) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                FloatingSapoIcon(state: .recording, size: 32)
                PillDivider()
                // The chips row already widened the pill — spend that width
                // on a longer, livelier waveform.
                MiniEqualizerView(audioLevelPublisher: audioLevelPublisher, barCount: 11)

                if showsNoSpeechHint {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("overlay.no_speech".localized)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.sapoError)
                    .transition(.opacity)
                } else if isEditSession {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 11, weight: .semibold))
                        Text("overlay.edit_mode".localized)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.aiPolish)
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

            if !isEditSession {
                OverlayModeChips(
                    onModeSelected: onModeSelected,
                    onTranslationToggled: onTranslationToggled
                )
            }
        }
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
    let timeoutSeconds: UInt64

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
                let remaining = max(0, Int(timeoutSeconds) - elapsed)
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
    var onRepolish: (() -> Void)?
    var onVoiceEdit: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var iconScale: CGFloat = 0
    @State private var showGlow = false
    @State private var showRecopied = false
    @AppStorage(Constants.StorageKeys.aiPolishEnabled) private var aiPolishEnabled = false

    private static let contentWidth: CGFloat = 400
    private static let transcriptFontSize: CGFloat = 12
    private static let transcriptLineSpacing: CGFloat = 3.5
    /// Measured text taller than this (~10 lines) scrolls in a fixed viewport;
    /// anything shorter hugs its real height so the pill never shows a mostly
    /// empty scroll area.
    private static let scrollThresholdHeight: CGFloat = 178
    private static let scrollViewportHeight: CGFloat = 184

    /// Real Core Text measurement at the pill's wrap width. The layout never
    /// trusts this number for sizing — the concrete-width frame plus
    /// `fixedSize(vertical:)` below re-measure inside SwiftUI — it only picks
    /// hugging vs scroll and slims single-line pills. The old estimate
    /// (characters per line) routinely undersized multi-line text, and under
    /// the overlay's ideal-size layout a `maxWidth` frame reports one line of
    /// height, so the transcript overflowed past the pill background and the
    /// fixed window edge (clipped chips and dock chip).
    private static func measuredTextSize(_ text: String) -> CGSize {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = transcriptLineSpacing
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: transcriptFontSize),
                .paragraphStyle: paragraphStyle,
            ]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    /// Concrete wrap width: measured single lines keep the pill slim (plus a
    /// small cushion against Core Text/SwiftUI rounding differences), longer
    /// text uses the full column.
    private static func transcriptWidth(for measuredSize: CGSize) -> CGFloat {
        min(measuredSize.width + 2, contentWidth)
    }

    private var transcriptText: some View {
        Text(text)
            .font(.system(size: Self.transcriptFontSize))
            .lineSpacing(Self.transcriptLineSpacing)
            .foregroundColor(.primary.opacity(0.9))
            .textSelection(.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.sapoGreen)
                    .scaleEffect(iconScale)

                Text((showRecopied ? "overlay.copied_again" : "overlay.copied").localized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.sapoGreen)

                Spacer(minLength: 16)

                if aiPolishEnabled, onVoiceEdit != nil, !text.isEmpty {
                    Button {
                        onVoiceEdit?()
                    } label: {
                        Image(systemName: "mic.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.aiPolish)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.aiPolish.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("overlay.voice_edit".localized)
                }

                Button {
                    PasteManager.copyToClipboard(text)
                    showRecopied = true
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("overlay.copy".localized)

                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("overlay.close".localized)
            }

            if !text.isEmpty {
                // The hosting pill lays out at its ideal size, so a ScrollView
                // would grow to the full transcript height. Short texts hug
                // their measured content; only genuinely long ones get a
                // fixed, scrollable viewport — a fixed height on a 3-line
                // text reads as a giant empty pill.
                let measuredSize = Self.measuredTextSize(text)
                if measuredSize.height <= Self.scrollThresholdHeight {
                    transcriptText
                        .frame(width: Self.transcriptWidth(for: measuredSize), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        transcriptText
                            .frame(width: Self.contentWidth, alignment: .leading)
                            .padding(.bottom, 6)
                    }
                    .frame(width: Self.contentWidth, height: Self.scrollViewportHeight)
                }
            }

            if aiPolishEnabled && !text.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("overlay.repolish_hint".localized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    OverlayModeChips(
                        onModeSelected: { _ in onRepolish?() },
                        onTranslationToggled: { _ in onRepolish?() }
                    )
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: Self.contentWidth)
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

/// Slim always-visible bar at the anchor position — the overlay's permanent
/// resting fixture the droplet pill detaches from. Hover only highlights it
/// as an affordance; a click toggles the last transcription open/closed, so a
/// stray mouse pass at the screen edge does nothing.
struct DockedChipView: View {
    /// True while a droplet pill floats detached above the chip.
    var isExpanded: Bool = false
    var onTap: () -> Void

    @State private var isHovering = false
    @State private var stretch: CGFloat = 1

    var body: some View {
        Capsule()
            .fill(Color.sapoGreen.opacity(isExpanded ? 0.9 : (isHovering ? 0.95 : 0.65)))
            .frame(width: 24, height: 4)
            .frame(width: 34, height: 8)
            // Same ~46×12 footprint the chip had when it shared the pill's
            // background, now self-contained.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 3)
            )
            .scaleEffect(x: 1, y: stretch)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
            .onTapGesture(perform: onTap)
            .onChange(of: isExpanded) { _, _ in
                splashBounce()
            }
            .help("overlay.dock_last".localized)
    }

    /// Squash-and-stretch splash as the droplet detaches from or falls back
    /// into the chip — sells the "drop separating" read on both directions.
    private func splashBounce() {
        withAnimation(.spring(response: 0.14, dampingFraction: 0.4)) {
            stretch = 1.75
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
                stretch = 1
            }
        }
    }
}

struct CancelledPillView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.secondary)

            Text("overlay.cancelled_saved".localized)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
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
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // A concrete width (maxWidth cannot wrap under the pill's
                // ideal-size layout) so long failure messages break into
                // lines instead of widening the pill past the screen.
                .frame(width: message.count > 50 ? 340 : nil, alignment: .leading)

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
    RoundedRectangle(cornerRadius: 26, style: .continuous)
        .strokeBorder(color.opacity(isVisible ? 0.4 : 0), lineWidth: 1.5)
        .padding(.horizontal, -20)
        .padding(.vertical, -12)
}
