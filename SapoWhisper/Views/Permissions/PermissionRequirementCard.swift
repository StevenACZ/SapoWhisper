//
//  PermissionRequirementCard.swift
//  SapoWhisper
//
//  Renders a polished card for one macOS permission.
//

import SwiftUI

struct PermissionRequirementCard: View {
    let permission: AppPermission
    let index: Int
    let isLast: Bool
    let isGranted: Bool
    let onActivate: (AppPermission) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(toneColor.opacity(0.14))
                        .frame(width: 28, height: 28)

                    Text("\(index)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(toneColor)
                }

                Rectangle()
                    .fill(toneColor.opacity(0.10))
                    .frame(width: 1, height: 34)
                    .opacity(isLast ? 0 : 1)
            }

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(toneColor.opacity(0.12))
                        .frame(width: 46, height: 46)

                    Image(systemName: permission.iconName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(toneColor)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(permission.title)
                            .font(.body.weight(.semibold))

                        Text(isGranted ? "permissions.status.active".localized : "permissions.status.pending".localized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(toneColor.opacity(0.12))
                            )
                            .foregroundStyle(toneColor)
                    }

                    Text(permission.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label(permission.detailText(isGranted: isGranted), systemImage: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Group {
                    if isGranted {
                        Label("permissions.card.ready".localized, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button("permissions.activate".localized) {
                            onActivate(permission)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(Color(nsColor: permission.accentColor))
                    }
                }
                .frame(minWidth: 84, alignment: .trailing)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var toneColor: Color {
        isGranted ? .green : Color(nsColor: permission.accentColor)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
            .overlay(
                LinearGradient(
                    colors: [
                        toneColor.opacity(0.10),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(toneColor.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}
