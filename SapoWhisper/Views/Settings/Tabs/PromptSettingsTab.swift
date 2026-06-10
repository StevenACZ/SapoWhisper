//
//  PromptSettingsTab.swift
//  SapoWhisper
//

import SwiftUI

struct PromptSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AIPolishSettingsCard()
                PromptContextSettingsCard()
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }
}

#Preview("Prompt Settings") {
    PromptSettingsTab()
        .frame(width: 780, height: 720)
}
