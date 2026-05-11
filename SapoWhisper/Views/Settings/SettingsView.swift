//
//  SettingsView.swift
//  SapoWhisper
//
//

import Foundation
import SwiftUI
import os

/// Vista principal de configuración con tabs
/// Se abre desde el botón "Configuración" en el menú
struct SettingsView: View {
    let viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    @State private var tabSwitchStartedAt: CFAbsoluteTime?

    var body: some View {
        VStack(spacing: 0) {
            // Contenido del tab seleccionado
            selectedTabContent
        }
        .frame(width: 480, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: tabSelection) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("close".localized) {
                    dismiss()
                }
            }
        }
        .onAppear {
            SapoLog.settings.info("Settings view appeared tab=\(selectedTab.rawValue, privacy: .public)")
            PerformanceDiagnostics.logRuntimeSnapshot(reason: "settings-view-appear", force: true)
        }
        .onChange(of: selectedTab) { _, newTab in
            DispatchQueue.main.async {
                logTabRendered(newTab)
            }
        }
    }

    // MARK: - Tab Content

    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                guard newTab != selectedTab else { return }
                let previousTab = selectedTab
                tabSwitchStartedAt = CFAbsoluteTimeGetCurrent()
                SapoLog.settings.info(
                    "Settings tab selected from=\(previousTab.rawValue, privacy: .public) to=\(newTab.rawValue, privacy: .public)"
                )
                selectedTab = newTab
            }
        )
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTab()
        case .engine:
            EngineSettingsTab(viewModel: viewModel)
        case .hotkey:
            HotkeySettingsTab()
        case .about:
            AboutSettingsTab()
        }
    }

    private func logTabRendered(_ tab: SettingsTab) {
        let elapsed = tabSwitchStartedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? 0
        SapoLog.settings.info(
            "Settings tab rendered tab=\(tab.rawValue, privacy: .public) elapsed=\(elapsed, privacy: .public)ms"
        )
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "settings-tab-rendered",
            context: "tab=\(tab.rawValue) elapsedMs=\(elapsed)",
            force: true
        )
        tabSwitchStartedAt = nil
    }
}

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case engine
    case hotkey
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "tab.general".localized
        case .engine:
            return "tab.engine".localized
        case .hotkey:
            return "tab.hotkey".localized
        case .about:
            return "tab.about".localized
        }
    }
}

#Preview("Settings Window") {
    SettingsView(viewModel: SapoWhisperViewModel())
}
