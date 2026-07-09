//
//  AIPolishComponents.swift
//  SapoWhisper
//

import SwiftUI

/// Compact "fidelity at max" badge; the full explanation lives in its tooltip.
struct AIPolishFidelityBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("ai.polish.fidelity_max".localized)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color.sapoGreenText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.sapoGreen.opacity(0.10), in: Capsule())
        .help("ai.polish.desc".localized)
    }
}

/// Prominent enable/disable toggle for the AI polish feature.
struct AIPolishHeroToggle: View {
    @Binding var isOn: Bool
    let activeSubtitle: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 34, height: 34)
                    .shadow(color: isOn ? Color.sapoGreen.opacity(0.35) : .clear, radius: 4, y: 1)

                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("ai.polish.enable".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(isOn ? activeSubtitle : "ai.polish.enable_subtitle".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color.sapoGreen)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.sapoGreen.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn ? Color.sapoGreen.opacity(0.38) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }

    private var iconBackground: LinearGradient {
        if isOn {
            return LinearGradient(
                colors: [Color.purple, Color.sapoGreen],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.secondary.opacity(0.22), Color.secondary.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
