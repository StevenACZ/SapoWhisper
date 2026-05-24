//
//  SettingsPermissionsSection.swift
//  SapoWhisper
//
//  Keeps granted permissions compact while preserving the guided review flow.
//

import SwiftUI

struct SettingsPermissionsSection: View {
    @State private var grantedPermissions: Set<AppPermission> = []
    @State private var isExpanded = false
    @State private var didInitializeExpansion = false
    @State private var isValidatingMicrophone = false
    @State private var isHoveringSummary = false

    private var allPermissionsGranted: Bool {
        grantedPermissions.count == AppPermission.allCases.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allPermissionsGranted {
                expandableSummary
            } else {
                permissionRows
                reviewButton
            }
        }
        .onAppear {
            refreshPermissionStatuses()
            validateMicrophoneStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
            validateMicrophoneStatus()
        }
    }

    @ViewBuilder
    private var expandableSummary: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            compactReadySummary
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringSummary = hovering
        }

        if isExpanded {
            VStack(spacing: 6) {
                permissionRows
                reviewButton
                    .padding(.top, 4)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var permissionRows: some View {
        VStack(spacing: 6) {
            ForEach(AppPermission.allCases) { permission in
                PermissionStatusRow(permission: permission)
            }
        }
    }

    private var reviewButton: some View {
        Button("permissions.review".localized) {
            PermissionRequirementsWindowController.shared.showWindow(force: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var compactReadySummary: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 40, height: 40)

                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("settings.permissions_all_active".localized)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("settings.permissions_all_active_desc".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("settings.permissions_all_active_badge".localized(AppPermission.allCases.count))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.green.opacity(0.14))
                )
                .foregroundStyle(.green)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isHoveringSummary
                        ? Color.primary.opacity(0.06)
                        : Color.clear
                )
        )
    }

    private func refreshPermissionStatuses() {
        let nextPermissions = Set(AppPermission.allCases.filter { PermissionService.shared.isGranted($0) })
        let nextAllGranted = nextPermissions.count == AppPermission.allCases.count

        grantedPermissions = nextPermissions

        if !didInitializeExpansion {
            isExpanded = !nextAllGranted
            didInitializeExpansion = true
        } else if !nextAllGranted {
            isExpanded = true
        }
    }

    private func validateMicrophoneStatus() {
        guard !grantedPermissions.contains(.microphone), !isValidatingMicrophone else { return }

        isValidatingMicrophone = true
        Task { @MainActor in
            if await MicrophonePermission.refreshFromAudioInputProbeIfNeeded() {
                refreshPermissionStatuses()
            }
            isValidatingMicrophone = false
        }
    }
}

#Preview("Settings Permissions Section") {
    VStack(alignment: .leading, spacing: 12) {
        Label("settings.permissions".localized, systemImage: "hand.raised.fill")
            .font(.headline)
        SettingsPermissionsSection()
    }
    .padding()
    .frame(width: 360, height: 280)
}
