//
//  EngineModeButton.swift
//  SapoWhisper
//

import SwiftUI

/// Shared selectable mode row used by the engine settings cards (Deepgram
/// batch/realtime, ElevenLabs batch/realtime). Replaces two byte-identical
/// private `*ModeButton` views; callers pass the mode's `icon`, `displayName`
/// and `description` directly.
struct EngineModeButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .sapoGreen : .secondary.opacity(0.5))
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.sapoGreen.opacity(0.1) : Color(NSColor.windowBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.sapoGreen.opacity(0.5) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
