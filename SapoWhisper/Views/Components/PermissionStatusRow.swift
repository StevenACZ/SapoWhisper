//
//  PermissionStatusRow.swift
//  SapoWhisper
//
//  Displays a guided permission row inside Settings.
//

import SwiftUI

struct PermissionStatusRow: View {
    let permission: AppPermission

    @State private var isGranted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: permission.accentColor).opacity(isGranted ? 0.14 : 0.10))
                    .frame(width: 40, height: 40)

                Image(systemName: permission.iconName)
                    .font(.title3)
                    .foregroundStyle(isGranted ? .green : Color(nsColor: permission.accentColor))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(permission.title)
                        .font(.body.weight(.semibold))

                    Text(isGranted ? "permissions.status.active".localized : "permissions.status.pending".localized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isGranted ? Color.green.opacity(0.14) : Color.orange.opacity(0.14))
                        )
                        .foregroundStyle(isGranted ? .green : .orange)
                }

                Text(permission.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isGranted {
                    Text("permissions.settings.row_hint".localized)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("permissions.activate".localized) {
                    PermissionService.shared.requestInteractively(permission)
                    refreshPermissionStatus()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color(nsColor: permission.accentColor))
            }
        }
        .padding(.vertical, 6)
        .onAppear(perform: refreshPermissionStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() {
        isGranted = PermissionService.shared.isGranted(permission)
    }
}
