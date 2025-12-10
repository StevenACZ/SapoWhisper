//
//  SettingsView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Vista principal de configuración con tabs
/// Se abre desde el botón "Configuración" en el menú
struct SettingsView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        VStack(spacing: 0) {
            // Contenido del tab seleccionado
            selectedTabContent
            
            Divider()
            
            // Footer
            footerSection
        }
        .frame(width: 480, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
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
    }
    
    // MARK: - Tab Content
    
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
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack {
            Text("v\(Constants.appVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("close".localized) {
                dismiss()
            }
            .keyboardShortcut(.escape)
            .buttonStyle(.borderedProminent)
            .tint(.sapoGreen)
        }
        .padding()
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

#Preview {
    SettingsView(viewModel: SapoWhisperViewModel())
}
