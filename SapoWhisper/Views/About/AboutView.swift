//
//  AboutView.swift
//  SapoWhisper
//
//  Standalone about window content, opened from the menu bar popover.
//

import SwiftUI

/// About window: app identity, version, feature chips, and links.
struct AboutView: View {
    @State private var tapCount = 0
    @State private var showLoadingIcon = false
    @State private var iconBounce = false
    @State private var versionCopied = false
    @State private var isHoveringVersion = false

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var year: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        VStack(spacing: 18) {
            heroSection
            taglineSection
            featureChips
            separator
            linksSection
            footerSection
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(backgroundLayer)
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(spacing: 10) {
            appIcon
                .scaleEffect(iconBounce ? 1.15 : 1.0)
                .animation(.interpolatingSpring(stiffness: 300, damping: 10), value: iconBounce)
                .onTapGesture { handleIconTap() }
                .shadow(color: Color.sapoGreen.opacity(0.35), radius: 10, y: 5)

            Text("app_name".localized)
                .font(.system(size: 24, weight: .bold))

            versionButton

            updateStatus
        }
    }

    /// Update capsule mirroring `UpdateManager.phase`, plus a manual
    /// "check for updates" affordance when nothing is pending.
    @ViewBuilder
    private var updateStatus: some View {
        let manager = UpdateManager.shared

        switch manager.phase {
        case .idle:
            checkForUpdatesButton(manager)

        case .available(let version):
            VStack(spacing: 5) {
                Button {
                    manager.installPendingUpdate()
                } label: {
                    updateCapsule(icon: "arrow.down.circle", text: "about.update_install".localized(version))
                }
                .buttonStyle(.plain)

                if manager.releasePageURL != nil {
                    Button {
                        manager.openReleasePage()
                    } label: {
                        Text("about.update_release_notes".localized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }

        case .downloading(let fraction):
            updateProgressCapsule(
                text: "about.update_downloading".localized
                    + (fraction.map { " \(Int($0 * 100))%" } ?? ""))

        case .installing:
            updateProgressCapsule(text: "about.update_installing".localized)

        case .failed:
            Button {
                manager.installPendingUpdate()
            } label: {
                updateCapsule(icon: "exclamationmark.arrow.circlepath", text: "about.update_retry".localized)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func checkForUpdatesButton(_ manager: UpdateManager) -> some View {
        switch manager.manualCheckStatus {
        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("about.update_check".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                Text("about.update_up_to_date".localized)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(Color.sapoGreen)
        case .idle:
            Button {
                manager.checkForUpdatesManually()
            } label: {
                Text("about.update_check".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .underline()
            }
            .buttonStyle(.plain)
        }
    }

    private func updateCapsule(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)

            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.sapoGreenText.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.sapoGreenText.opacity(0.22), lineWidth: 1))
        .foregroundStyle(Color.sapoGreenText)
    }

    private func updateProgressCapsule(text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)

            Text(text)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.sapoGreenText.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.sapoGreenText.opacity(0.22), lineWidth: 1))
        .foregroundStyle(Color.sapoGreenText)
    }

    /// Easter egg: 3 quick taps swap in the loading icon for a moment.
    @ViewBuilder
    private var appIcon: some View {
        if showLoadingIcon, let loadingIcon = NSImage(named: "DockIconLoading") {
            Image(nsImage: loadingIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)
        }
    }

    /// Version pill that copies "SapoWhisper vX.Y.Z" to the clipboard.
    private var versionButton: some View {
        Button(action: copyVersion) {
            HStack(spacing: 4) {
                Text(versionCopied ? "history.copied".localized : "v\(Constants.appVersion) · \(build)")
                    .font(.caption.monospaced())
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
        .animation(Constants.Animation.hover, value: isHoveringVersion)
        .animation(Constants.Animation.hover, value: versionCopied)
    }

    private var taglineSection: some View {
        Text("config.subtitle_info".localized)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var featureChips: some View {
        HStack(spacing: 8) {
            chip(icon: "mic.fill", label: "about.chip_dictation".localized)
            chip(icon: "sparkles", label: "about.chip_ai".localized)
            chip(icon: "lock.fill", label: "about.chip_private".localized)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
    }

    private var linksSection: some View {
        HStack(spacing: 10) {
            linkButton(icon: "link", label: "about.github".localized, url: "https://github.com/StevenACZ/SapoWhisper")
            linkButton(
                icon: "ladybug",
                label: "about.report_issue".localized,
                url: "https://github.com/StevenACZ/SapoWhisper/issues"
            )
        }
    }

    private var footerSection: some View {
        VStack(spacing: 3) {
            Text("made_by".localized)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("© \(year) StevenACZ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Builders

    private func chip(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)

            Text(label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.sapoGreen.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.sapoGreen.opacity(0.22), lineWidth: 1))
        .foregroundStyle(Color.sapoGreen)
    }

    private func linkButton(icon: String, label: String, url: String) -> some View {
        Button {
            if let target = URL(string: url) {
                NSWorkspace.shared.open(target)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)

                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(Constants.appName) v\(Constants.appVersion)", forType: .string)
        versionCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            versionCopied = false
        }
    }

    private func handleIconTap() {
        tapCount += 1

        if tapCount >= 3 {
            tapCount = 0
            withAnimation {
                iconBounce = true
                showLoadingIcon = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                iconBounce = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    iconBounce = true
                    showLoadingIcon = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    iconBounce = false
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if tapCount > 0 && tapCount < 3 {
                tapCount = 0
            }
        }
    }
}

#Preview("About") {
    AboutView()
}
