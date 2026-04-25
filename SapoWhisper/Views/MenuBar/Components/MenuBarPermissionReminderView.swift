//
//  MenuBarPermissionReminderView.swift
//  SapoWhisper
//
//  Shows the compact missing-permissions reminder inside the menu bar popover.
//

import SwiftUI

struct MenuBarPermissionReminderView: View {
    let onReview: () -> Void

    @State private var missingPermissions: [AppPermission] = []

    var body: some View {
        Group {
            if !missingPermissions.isEmpty {
                VStack(spacing: 0) {
                    PermissionSummaryBanner(missingPermissions: missingPermissions) {
                        onReview()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    Divider()
                        .padding(.horizontal)
                }
            }
        }
        .onAppear(perform: refreshMissingPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMissingPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshMissingPermissions()
        }
    }

    private func refreshMissingPermissions() {
        missingPermissions = PermissionService.shared.missingPermissions()
    }
}
