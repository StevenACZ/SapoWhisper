//
//  PermissionSummaryBanner.swift
//  SapoWhisper
//
//  Highlights missing permissions at the top of the menu bar popover.
//

import SwiftUI

struct PermissionSummaryBanner: View {
    let missingPermissions: [AppPermission]
    let onReview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("permissions.banner.title".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("permissions.banner.body".localized(permissionListText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("permissions.review".localized) {
                onReview()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                )
        )
    }

    private var permissionListText: String {
        let titles = missingPermissions.map(\.title)

        switch titles.count {
        case 0:
            return "permissions.banner.generic_permissions".localized
        case 1:
            return titles[0]
        case 2:
            return "\(titles[0]) \( "permissions.banner.and".localized ) \(titles[1])"
        default:
            let head = titles.dropLast().joined(separator: ", ")
            return "\(head) \( "permissions.banner.and".localized ) \(titles.last ?? "")"
        }
    }
}
