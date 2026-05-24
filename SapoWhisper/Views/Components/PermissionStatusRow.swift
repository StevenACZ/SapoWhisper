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
    @State private var isValidatingMicrophone = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(iconBackgroundColor)
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

                    if !isGranted {
                        Text("permissions.status.pending".localized)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.orange.opacity(0.14))
                            )
                            .foregroundStyle(.orange)
                    }
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
        .onAppear {
            refreshPermissionStatus()
            validateMicrophoneStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
            validateMicrophoneStatus()
        }
    }

    private func refreshPermissionStatus() {
        let nextStatus = PermissionService.shared.isGranted(permission)
        guard isGranted != nextStatus else { return }
        isGranted = nextStatus
    }

    private func validateMicrophoneStatus() {
        guard permission == .microphone, !isGranted, !isValidatingMicrophone else { return }

        isValidatingMicrophone = true
        Task { @MainActor in
            if await MicrophonePermission.refreshFromAudioInputProbeIfNeeded() {
                refreshPermissionStatus()
            }
            isValidatingMicrophone = false
        }
    }

    private var iconBackgroundColor: Color {
        isGranted
            ? Color.green.opacity(0.12)
            : Color(nsColor: permission.accentColor).opacity(0.10)
    }
}
