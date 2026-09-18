//
//  MenuBarRows.swift
//  SapoWhisper
//
//  Shared row components used by the menu bar popover.
//

import Combine
import SwiftUI

struct HotkeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
    }
}

struct RecordingTimer: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.recording)
                .frame(width: 8, height: 8)

            Text(formattedDuration)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.recording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.recording.opacity(0.1))
        .cornerRadius(Constants.Sizes.smallCornerRadius)
    }

    private var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let milliseconds = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, milliseconds)
    }
}

/// Hosts RecordingTimer behind its own duration subscription so the 10 Hz
/// ticks re-render only this row instead of feeding the duration through the
/// whole popover body.
struct RecordingTimerRow: View {
    let durationPublisher: AnyPublisher<TimeInterval, Never>

    @State private var duration: TimeInterval = 0

    var body: some View {
        RecordingTimer(duration: duration)
            .onReceive(durationPublisher) { duration = $0 }
    }
}

struct RecordingStatusCaption: View {
    let durationPublisher: AnyPublisher<TimeInterval, Never>

    @State private var duration: TimeInterval = 0

    var body: some View {
        Text("menu.recording".localized(String(Int(duration))))
            .font(.caption)
            .foregroundColor(.secondary)
            .onReceive(durationPublisher.map { $0.rounded(.down) }.removeDuplicates()) { duration = $0 }
    }
}

/// Update card shown under the popover header: a pending update installs in
/// one click, downloads with visible progress, then offers install now / later.
struct UpdateCard: View {
    let manager: UpdateManager

    private static let buttonShape = RoundedRectangle(
        cornerRadius: Constants.Sizes.smallCornerRadius, style: .continuous)

    var body: some View {
        if manager.phase == .idle {
            EmptyView()
        } else {
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch manager.phase {
            case .idle:
                EmptyView()

            case .available(let version):
                heading(
                    icon: "arrow.down.circle.fill",
                    title: "update.card.available_title".localized(version),
                    subtitle: "update.card.available_subtitle".localized
                )

                primaryButton("update.card.update".localized) {
                    manager.installPendingUpdate()
                }

            case .downloading(let fraction):
                heading(
                    icon: "arrow.down.circle",
                    title: versionedTitle(
                        "update.card.downloading_title",
                        generic: "update.card.downloading_title_generic",
                        version: manager.pendingVersion
                    ),
                    subtitle: nil
                )

                progressBar(fraction: fraction)

            case .readyToInstall(let version):
                heading(
                    icon: "checkmark.circle.fill",
                    title: versionedTitle(
                        "update.card.ready_title",
                        generic: "update.card.ready_title_generic",
                        version: version
                    ),
                    subtitle: "update.card.ready_subtitle".localized
                )

                HStack(spacing: 8) {
                    primaryButton("update.card.install_now".localized) {
                        manager.installNow()
                    }

                    if manager.canPostpone {
                        secondaryButton("update.card.later".localized) {
                            manager.installLater()
                        }
                    }
                }

            case .installing:
                heading(
                    icon: "arrow.triangle.2.circlepath",
                    title: versionedTitle(
                        "update.card.installing_title",
                        generic: "update.card.installing_title_generic",
                        version: manager.pendingVersion
                    ),
                    subtitle: "update.card.installing_subtitle".localized
                )

                progressBar(fraction: nil)

            case .failed:
                heading(
                    icon: "exclamationmark.arrow.circlepath",
                    title: "update.card.failed_title".localized,
                    subtitle: "update.card.failed_subtitle".localized
                )

                primaryButton("update.card.retry".localized) {
                    manager.installNow()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Constants.Sizes.cornerRadius, style: .continuous)
                .fill(Color.sapoGreenText.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Sizes.cornerRadius, style: .continuous)
                .strokeBorder(Color.sapoGreenText.opacity(0.22), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: manager.phase)
    }

    private func versionedTitle(_ key: String, generic: String, version: String?) -> String {
        guard let version, !version.isEmpty else { return generic.localized }
        return key.localized(version)
    }

    private func heading(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color.sapoGreenText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func progressBar(fraction: Double?) -> some View {
        HStack(spacing: 8) {
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(Color.sapoGreenText)

            if let fraction {
                Text("\(Int(fraction * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    LinearGradient(
                        colors: [Color.sapoGreen, Color.sapoGreenDark],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Self.buttonShape)
                .contentShape(Self.buttonShape)
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isDestructive ? .red : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(isDestructive ? .red : .primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if !isDestructive {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(isHovering ? Color(NSColor.controlBackgroundColor) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
