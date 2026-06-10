//
//  PermissionRequirementsView.swift
//  SapoWhisper
//
//  Explains which permissions are missing before the full app flow can continue.
//

import Combine
import SwiftUI

struct PermissionRequirementsView: View {
    static let windowSize = CGSize(width: 520, height: 560)

    let onActivate: (AppPermission) -> Void
    let onClose: () -> Void
    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
    private let previewGrantedPermissions: Set<AppPermission>?

    @Environment(\.colorScheme) private var colorScheme
    @State private var grantedPermissions: Set<AppPermission> = []
    @State private var isValidatingMicrophone = false

    init(
        previewGrantedPermissions: Set<AppPermission>? = nil,
        onActivate: @escaping (AppPermission) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.previewGrantedPermissions = previewGrantedPermissions
        self.onActivate = onActivate
        self.onClose = onClose
        _grantedPermissions = State(initialValue: previewGrantedPermissions ?? [])
    }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(alignment: .leading, spacing: 14) {
                PermissionRequirementsIntroView(missingCount: missingCount)

                VStack(alignment: .leading, spacing: 12) {
                    Text("permissions.window.section_title".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(AppPermission.allCases.enumerated()), id: \.element) { index, permission in
                        PermissionRequirementCard(
                            permission: permission,
                            index: index + 1,
                            isLast: index == AppPermission.allCases.count - 1,
                            isGranted: grantedPermissions.contains(permission),
                            onActivate: onActivate
                        )
                    }
                }

                Spacer(minLength: 6)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshPermissionStatuses()
            validateMicrophoneAfterSettingsReturn()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatuses()
            validateMicrophoneAfterSettingsReturn()
        }
        .onReceive(refreshTimer) { _ in
            refreshPermissionStatuses()
        }
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.42 : 0.72),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(footerMessage, systemImage: footerIconName)
                .font(.caption)
                .foregroundStyle(footerColor)

            Spacer()

            Button(footerButtonTitle) {
                onClose()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var missingCount: Int {
        AppPermission.allCases.filter { !grantedPermissions.contains($0) }.count
    }

    private var footerMessage: String {
        missingCount == 0
            ? "permissions.window.footer_ready".localized
            : "permissions.window.footer_pending".localized
    }

    private var footerIconName: String {
        missingCount == 0
            ? "checkmark.circle.fill"
            : "clock.arrow.trianglehead.counterclockwise.rotate.90"
    }

    private var footerColor: Color {
        missingCount == 0 ? .green : .secondary
    }

    private var footerButtonTitle: String {
        missingCount == 0
            ? "permissions.window.close_ready".localized
            : "permissions.window.close_pending".localized
    }

    private func refreshPermissionStatuses() {
        if let previewGrantedPermissions {
            updateGrantedPermissions(previewGrantedPermissions)
            return
        }

        let nextPermissions = Set(AppPermission.allCases.filter { PermissionService.shared.isGranted($0) })
        updateGrantedPermissions(nextPermissions)
    }

    private func updateGrantedPermissions(_ nextPermissions: Set<AppPermission>) {
        guard grantedPermissions != nextPermissions else { return }
        withAnimation(.smooth(duration: 0.3)) {
            grantedPermissions = nextPermissions
        }
    }

    private func validateMicrophoneAfterSettingsReturn() {
        guard previewGrantedPermissions == nil else { return }
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

#Preview {
    PermissionRequirementsView(
        previewGrantedPermissions: [.microphone],
        onActivate: { _ in },
        onClose: {}
    )
    .frame(
        width: PermissionRequirementsView.windowSize.width,
        height: PermissionRequirementsView.windowSize.height
    )
}

#Preview("Dark") {
    PermissionRequirementsView(
        previewGrantedPermissions: [.microphone],
        onActivate: { _ in },
        onClose: {}
    )
    .frame(
        width: PermissionRequirementsView.windowSize.width,
        height: PermissionRequirementsView.windowSize.height
    )
    .preferredColorScheme(.dark)
}
