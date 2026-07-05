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

/// Live "Recording... Ns" caption behind its own subscription, for the same
/// reason as RecordingTimerRow: the caption is the only header element that
/// needs the 10 Hz duration ticks.
struct RecordingStatusCaption: View {
    let durationPublisher: AnyPublisher<TimeInterval, Never>

    @State private var duration: TimeInterval = 0

    var body: some View {
        Text("menu.recording".localized(String(Int(duration))))
            .font(.caption)
            .foregroundColor(.secondary)
            .onReceive(durationPublisher) { duration = $0 }
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
