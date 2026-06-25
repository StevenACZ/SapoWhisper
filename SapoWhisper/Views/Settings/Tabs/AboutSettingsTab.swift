//
//  AboutSettingsTab.swift
//  SapoWhisper
//
//

import SwiftUI

/// Tab de información sobre la aplicación
struct AboutSettingsTab: View {
    @State private var tapCount = 0
    @State private var showLoadingIcon = false
    @State private var iconBounce = false
    @State private var versionCopied = false
    @State private var isHoveringVersion = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroSection
                privacySection
                permissionsSection
                creditsSection
            }
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                // Easter egg: 3 clics cambia el icono
                Group {
                    if showLoadingIcon, let loadingIcon = NSImage(named: "DockIconLoading") {
                        Image(nsImage: loadingIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .scaleEffect(iconBounce ? 1.2 : 1.0)
                .animation(.interpolatingSpring(stiffness: 300, damping: 10), value: iconBounce)
                .onTapGesture {
                    handleIconTap()
                }
            }

            VStack(spacing: 4) {
                Text("app_name".localized)
                    .font(.title2)
                    .fontWeight(.bold)

                versionButton

                Text("config.subtitle_info".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    /// Version pill that copies "SapoWhisper vX.Y.Z" to the clipboard.
    private var versionButton: some View {
        Button(action: copyVersion) {
            HStack(spacing: 4) {
                Text(versionCopied ? "history.copied".localized : "v\(Constants.appVersion)")
                    .font(.caption)
                    .foregroundColor(versionCopied ? Color.sapoGreen : .secondary)
                    .contentTransition(.opacity)

                Image(systemName: versionCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundColor(versionCopied ? Color.sapoGreen : .secondary)
                    .opacity(versionCopied || isHoveringVersion ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isHoveringVersion ? Color.secondary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringVersion = $0 }
        .help("about.version_copy_help".localized)
        .animation(.easeOut(duration: 0.15), value: isHoveringVersion)
        .animation(.easeOut(duration: 0.15), value: versionCopied)
    }

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(Constants.appName) v\(Constants.appVersion)", forType: .string)
        versionCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            versionCopied = false
        }
    }

    // MARK: - Easter Egg Handler

    private func handleIconTap() {
        tapCount += 1

        if tapCount >= 3 {
            // Activar easter egg
            tapCount = 0

            // Efecto de rebote al cambiar
            withAnimation {
                iconBounce = true
                showLoadingIcon = true
            }

            // Quitar el rebote después de la animación
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                iconBounce = false
            }

            // Volver al icono normal después de 3 segundos
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    iconBounce = true
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showLoadingIcon = false

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        iconBounce = false
                    }
                }
            }
        }

        // Reset del contador después de 1 segundo sin clics
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if tapCount > 0 && tapCount < 3 {
                tapCount = 0
            }
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        SettingsCard(icon: "lock.shield.fill", title: "info.privacy_title".localized) {
            VStack(alignment: .leading, spacing: 12) {
                privacyRow(
                    icon: TranscriptionEngine.whisperLocal.icon,
                    title: TranscriptionEngine.whisperLocal.displayName,
                    detail: "info.privacy.whisper".localized
                )
                privacyRow(
                    icon: TranscriptionEngine.deepgram.icon,
                    title: TranscriptionEngine.deepgram.displayName,
                    detail: "info.privacy.deepgram".localized
                )
                privacyRow(
                    icon: TranscriptionEngine.localAIServer.icon,
                    title: TranscriptionEngine.localAIServer.displayName,
                    detail: "info.privacy.local_ai".localized
                )
                privacyRow(
                    icon: TranscriptionEngine.elevenLabsScribe.icon,
                    title: TranscriptionEngine.elevenLabsScribe.displayName,
                    detail: "info.privacy.elevenlabs".localized
                )
                privacyRow(
                    icon: "sparkles",
                    title: "ai.polish.title".localized,
                    detail: "info.privacy.ai_polish".localized
                )
            }
        }
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.sapoGreen)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Permissions Section

    private var permissionsSection: some View {
        InfoSection(
            icon: "hand.raised.fill",
            title: "info.permissions_title".localized,
            content: "info.permissions_body".localized
        )
    }

    // MARK: - Credits Section

    private var creditsSection: some View {
        VStack(spacing: 8) {
            Divider()
                .frame(width: 200)

            VStack(spacing: 8) {
                Text("made_by".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("about.open_source".localized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview("About") {
    AboutSettingsTab()
        .frame(width: 480, height: 600)
}
