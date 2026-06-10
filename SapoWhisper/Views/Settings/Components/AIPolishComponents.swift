//
//  AIPolishComponents.swift
//  SapoWhisper
//

import SwiftUI

/// Titled control tile used by the AI polish behavior pickers. Rendered as a
/// soft card so the three pickers read as one row of equal options; pair with
/// `.fixedSize(horizontal: false, vertical: true)` on the containing HStack
/// so every tile stretches to the tallest one. The optional footer anchors to
/// the bottom of the tile, filling space tiles with short detail text leave.
struct AIPolishSettingRow<Control: View, Footer: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: () -> Control
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            control()

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            footer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

extension AIPolishSettingRow where Footer == EmptyView {
    init(title: String, detail: String, @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, detail: detail, control: control, footer: { EmptyView() })
    }
}

/// Compact "fidelity at max" badge; the full explanation lives in its tooltip.
struct AIPolishFidelityBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("ai.polish.fidelity_max".localized)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color.sapoGreen)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.sapoGreen.opacity(0.10), in: Capsule())
        .help("ai.polish.desc".localized)
    }
}

/// Read-only pill shown when a value is locked by the active prompt profile.
struct FixedValuePill: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
