//
//  KeychainAccessRetryNotice.swift
//  SapoWhisper
//

import SwiftUI

/// Recovery path for a denied keychain consent: the saved API keys exist but
/// macOS refused the read, so every key field looks empty with nowhere to go.
/// One tap re-reads the item, which makes macOS show the consent dialog again.
struct KeychainAccessRetryNotice: View {
    /// Called after a successful retry so the host refreshes its key fields.
    let onRecovered: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("keychain.read_denied".localized, systemImage: "lock.slash")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("keychain.retry_access".localized) {
                if KeychainStore.retryDeniedRead() {
                    onRecovered()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}
