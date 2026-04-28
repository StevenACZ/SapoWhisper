//
//  MenuBarPermissionReminderView.swift
//  SapoWhisper
//
//  Shows the compact missing-permissions reminder inside the menu bar popover.
//

import SwiftUI

struct MenuBarPermissionReminderView: View {
    let missingPermissions: [AppPermission]
    let onReview: () -> Void

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
    }
}
