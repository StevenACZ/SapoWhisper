//
//  PermissionRequirementsIntroView.swift
//  SapoWhisper
//
//  Presents the introductory content for the permissions window.
//

import SwiftUI

struct PermissionRequirementsIntroView: View {
    let missingCount: Int

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // One compact header row: icon, title + subtitle, status badge. The
        // helper note rides along as a plain caption instead of a second box.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accentColor.opacity(0.22),
                                    accentColor.opacity(0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Image(systemName: "hand.raised.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText)
                        .font(.headline)

                    Text("permissions.window.subtitle".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(summaryBadgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.88 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(headerBorderColor, lineWidth: 1)
                    )
            )

            HStack(spacing: 8) {
                Image(systemName: helperIconName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accentColor)

                Text(helperText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private var accentColor: Color {
        missingCount == 0 ? .green : .orange
    }

    private var headerBorderColor: Color {
        colorScheme == .dark
            ? accentColor.opacity(0.20)
            : Color(nsColor: .separatorColor).opacity(0.16)
    }

    private var titleText: String {
        switch missingCount {
        case 0:
            return "permissions.window.hero_ready".localized
        case 1:
            return "permissions.window.hero_one".localized
        default:
            return "permissions.window.hero_many".localized
        }
    }

    private var summaryBadgeText: String {
        switch missingCount {
        case 0:
            return "permissions.window.badge_ready".localized
        case 1:
            return "permissions.window.badge_one".localized
        default:
            return "permissions.window.badge_many".localized(missingCount)
        }
    }

    private var helperIconName: String {
        missingCount == 0 ? "checkmark.circle.fill" : "sparkles"
    }

    private var helperText: String {
        missingCount == 0
            ? "permissions.window.helper_ready".localized
            : "permissions.window.helper_pending".localized
    }
}
