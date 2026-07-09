//
//  MenuBarHosts.swift
//  SapoWhisper
//

import SwiftUI

struct MenuBarPopoverHost: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @ObservedObject private var localizationManager = LocalizationManager.shared

    let missingPermissions: [AppPermission]
    let openSettings: () -> Void
    let openHistory: () -> Void
    let openPermissions: () -> Void
    let openWelcome: () -> Void
    let openAbout: () -> Void
    let closePopover: () -> Void

    var body: some View {
        MenuBarView(
            viewModel: viewModel,
            missingPermissions: missingPermissions,
            openSettingsAction: openSettings,
            openHistoryAction: openHistory,
            openPermissionsAction: openPermissions,
            openWelcomeAction: openWelcome,
            openAboutAction: openAbout,
            closeMenuBarAction: closePopover
        )
        .environment(\.locale, localizationManager.locale)
        .id(localizationManager.language)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsWindowHost: View {
    let viewModel: SapoWhisperViewModel
    @ObservedObject private var localizationManager = LocalizationManager.shared

    var body: some View {
        SettingsView(viewModel: viewModel)
            .environment(\.locale, localizationManager.locale)
            .tint(Constants.Colors.sapoGreen)
            .id(localizationManager.language)
    }
}

struct HistoryWindowHost: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @ObservedObject private var localizationManager = LocalizationManager.shared

    var body: some View {
        HistoryView(viewModel: viewModel)
            .environment(\.locale, localizationManager.locale)
            .tint(Constants.Colors.sapoGreen)
            .id(localizationManager.language)
    }
}

struct AboutWindowHost: View {
    @ObservedObject private var localizationManager = LocalizationManager.shared

    var body: some View {
        AboutView()
            .environment(\.locale, localizationManager.locale)
            .id(localizationManager.language)
    }
}
