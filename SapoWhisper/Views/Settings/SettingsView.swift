//
//  SettingsView.swift
//  SapoWhisper
//
//

import Foundation
import SwiftUI
import os

/// The settings tabs stay mounted in a ZStack (opacity toggle), so a hidden
/// tab never receives `onDisappear`. Live components (mic test meter) watch
/// this instead to release hardware when their tab stops being selected.
struct SettingsTabIsSelectedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var settingsTabIsSelected: Bool {
        get { self[SettingsTabIsSelectedKey.self] }
        set { self[SettingsTabIsSelectedKey.self] = newValue }
    }
}

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
        .frame(
            width: Constants.Windows.settingsSize.width,
            height: Constants.Windows.settingsSize.height
        )
        .background(Color(NSColor.windowBackgroundColor))
        .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: tabSelection) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.toolbarTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
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

    /// Each tab is kept alive in a ZStack and toggled via opacity so SwiftUI does not
    /// rebuild the subtree when the user switches tabs. This preserves scroll positions,
    /// pickers, drafts, and avoids re-running heavy init paths (vocabulary search, prompt
    /// editor state) every time the toolbar selection changes.
    private var selectedTabContent: some View {
        ZStack {
            tabContent(for: .general) {
                GeneralSettingsTab(viewModel: viewModel)
            }
            tabContent(for: .engine) {
                EngineSettingsTab(viewModel: viewModel)
            }
            tabContent(for: .vocabulary) {
                VocabularySettingsTab()
            }
            tabContent(for: .prompts) {
                PromptSettingsTab()
            }
            tabContent(for: .hotkey) {
                HotkeySettingsTab()
            }
        }
        .animation(Constants.Animation.reveal, value: selectedTab)
    }

    @ViewBuilder
    private func tabContent<Content: View>(for tab: SettingsTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .scaleEffect(selectedTab == tab ? 1 : 0.98)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .environment(\.settingsTabIsSelected, selectedTab == tab)
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
    case vocabulary
    case prompts
    case hotkey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "tab.general".localized
        case .engine:
            return "tab.engine".localized
        case .vocabulary:
            return "tab.vocabulary".localized
        case .prompts:
            return "tab.prompts".localized
        case .hotkey:
            return "tab.hotkey".localized
        }
    }

    var toolbarTitle: String {
        switch self {
        case .vocabulary:
            return "tab.vocabulary_short".localized
        case .prompts:
            return "tab.prompts_short".localized
        default:
            return title
        }
    }
}

#Preview("Settings Window") {
    SettingsView(viewModel: SapoWhisperViewModel())
}
